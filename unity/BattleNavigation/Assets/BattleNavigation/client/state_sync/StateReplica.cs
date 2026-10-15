// 每份网络Delta只合并到声明的完整基线；状态历史有界，实体删除显式应用。
using System;
using System.Collections.Generic;
using System.IO;
using Battle.Lesson03.StateSync.V1;
namespace BattleNavigation.StateSync
{
    internal sealed class StateReplica
    {
        private readonly Dictionary<uint, StateSnapshot> history = new Dictionary<uint, StateSnapshot>();
        public StateSnapshot Current { get; private set; }
        public uint EventSequence { get; private set; }
        public void Clear() { history.Clear(); Current = null; EventSequence = 0; }
        public StateSnapshot Install(StateSnapshot incoming)
        {
            if (incoming == null) return null;
            if (Current != null && incoming.SnapshotSeq <= Current.SnapshotSeq) return null;
            if (incoming.Units.Count > 32 || incoming.Bolts.Count > 64 || incoming.RemovedUnits.Count > 32 || incoming.RemovedBolts.Count > 64) throw new InvalidDataException("STATE_SIZE");
            StateSnapshot value;
            if (incoming.BaseSeq == 0) value = incoming.Clone();
            else
            {
                StateSnapshot basis;
                if (!history.TryGetValue(incoming.BaseSeq, out basis)) throw new InvalidDataException("BASE_GAP");
                value = incoming.Clone();
                value.Units.Clear();
                value.Bolts.Clear();
                var units = new SortedDictionary<uint, StateUnit>();
                var bolts = new SortedDictionary<uint, StateBolt>();
                foreach (var unit in basis.Units) units.Add(unit.InstanceId, unit.Clone());
                foreach (var bolt in basis.Bolts) bolts.Add(bolt.InstanceId, bolt.Clone());
                foreach (uint id in incoming.RemovedUnits) units.Remove(id);
                foreach (uint id in incoming.RemovedBolts) bolts.Remove(id);
                foreach (var unit in incoming.Units) units[unit.InstanceId] = unit.Clone();
                foreach (var bolt in incoming.Bolts) bolts[bolt.InstanceId] = bolt.Clone();
                foreach (var unit in units.Values) value.Units.Add(unit);
                foreach (var bolt in bolts.Values) value.Bolts.Add(bolt);
                value.BaseSeq = 0;
            }
            if (value.Units.Count > 32 || value.Bolts.Count > 64) throw new InvalidDataException("MERGED_STATE_SIZE");
            var ids = new HashSet<uint>();
            foreach (var unit in value.Units)
                if (unit.InstanceId == 0 || !ids.Add(unit.InstanceId) || unit.Position == null || unit.Hp > unit.MaxHp)
                    throw new InvalidDataException("UNIT_STATE");
            history[value.SnapshotSeq] = value;
            if (value.SnapshotSeq >= 64) history.Remove(value.SnapshotSeq - 64);
            // 若网络序号跨越多项，按数量淘汰，不能只删除恰好seq-64的条目。
            while (history.Count > 64)
            {
                uint first = uint.MaxValue;
                foreach (uint id in history.Keys) first = Math.Min(first, id);
                history.Remove(first);
            }
            Current = value;
            return value;
        }
        public bool Consume(StateEvent value)
        {
            if (value.EventSeq <= EventSequence) return false;
            if (value.EventSeq != EventSequence + 1) throw new InvalidDataException("EVENT_GAP");
            EventSequence = value.EventSeq;
            return true;
        }
        public void CoverEvents(uint watermark) { EventSequence = Math.Max(EventSequence, watermark); }
    }
}
