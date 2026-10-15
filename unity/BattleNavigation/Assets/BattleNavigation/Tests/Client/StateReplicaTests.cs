// 状态基线、删除与事件水位是客户端合同；测试不启动网络或依赖Render结果。
using System.IO;
using Battle.Navigation.V1;
using BattleNavigation.StateSync;
using NUnit.Framework;
namespace BattleNavigation.Tests
{
    public sealed class StateReplicaTests
    {
        private static StateSnapshot Full(uint sequence = 1)
        {
            var value = new StateSnapshot { SnapshotSeq = sequence, ServerTick = sequence * 3 };
            value.Units.Add(new StateUnit
            {
                InstanceId = 1001, UnitProfileId = 1, Hp = 100, MaxHp = 100,
                Position = new WorldPosition { XMm = 50 },
            });
            return value;
        }
        [Test]
        public void DeltaRequiresItsDeclaredBaseline()
        {
            var replica = new StateReplica();
            replica.Install(Full());
            var delta = new StateSnapshot { SnapshotSeq = 2, BaseSeq = 99 };
            Assert.Throws<InvalidDataException>(() => replica.Install(delta));
            Assert.AreEqual(1u, replica.Current.SnapshotSeq);
        }
        [Test]
        public void DeltaCarriesChangesAndDeletionWithoutMutatingBaseline()
        {
            var replica = new StateReplica();
            var full = Full();
            replica.Install(full);
            var delta = new StateSnapshot { SnapshotSeq = 2, BaseSeq = 1, ConsumedInputSeq = 6 };
            delta.Units.Add(new StateUnit { InstanceId = 1001, Hp = 90, MaxHp = 100, Position = new WorldPosition { XMm = 300 } });
            replica.Install(delta);
            Assert.AreEqual(50, full.Units[0].Position.XMm);
            Assert.AreEqual(300, replica.Current.Units[0].Position.XMm);
            Assert.AreEqual(6u, replica.Current.ConsumedInputSeq);
            var remove = new StateSnapshot { SnapshotSeq = 3, BaseSeq = 2 };
            remove.RemovedUnits.Add(1001);
            replica.Install(remove);
            Assert.AreEqual(0, replica.Current.Units.Count);
        }
        [Test]
        public void DuplicateEventsAreIgnoredAndGapsRequireRecovery()
        {
            var replica = new StateReplica();
            Assert.IsTrue(replica.Consume(new StateEvent { EventSeq = 1 }));
            Assert.IsFalse(replica.Consume(new StateEvent { EventSeq = 1 }));
            Assert.Throws<InvalidDataException>(() => replica.Consume(new StateEvent { EventSeq = 3 }));
            replica.CoverEvents(3);
            Assert.IsTrue(replica.Consume(new StateEvent { EventSeq = 4 }));
        }
        [Test]
        public void OldSnapshotsCannotUndoNewAuthority()
        {
            var replica = new StateReplica();
            replica.Install(Full(2));
            Assert.IsNull(replica.Install(Full(1)));
            Assert.AreEqual(2u, replica.Current.SnapshotSeq);
        }
        [Test]
        public void ADiscardedBaselineCannotBeGuessed()
        {
            var replica = new StateReplica();
            for (uint sequence = 1; sequence <= 80; ++sequence) replica.Install(Full(sequence));
            Assert.Throws<InvalidDataException>(() => replica.Install(new StateSnapshot { SnapshotSeq = 81, BaseSeq = 1 }));
        }
    }
}
