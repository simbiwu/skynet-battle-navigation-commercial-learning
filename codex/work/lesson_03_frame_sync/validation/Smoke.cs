// 职责：隔离验证Windows C#客户端、真实Gateway与Windows Native状态一致性。
using System;
using System.Threading.Tasks;
using BattleNavigation.FrameSync;
using Battle.Navigation.V1;
public static class Smoke
{
    public static async Task<int> Main()
    {
        using(var connection=await FrameConnection.Connect("127.0.0.1",19021))
        using(var native=new FrameNative(@"G:\simbi\dev\skynet-battle-navigation-commercial-learning\.frame_verify_windows\shared\navigation\battle_1001\battle_1001.bmap"))
        {
            var envelope=await connection.Request(CommandId.FrameJoin,new FrameJoinRequest{ScenarioId=1001});
            var joined=FrameJoinResponse.Parser.ParseFrom(envelope.Body);
            if(joined.Code!="OK" || native.RulesHash!=joined.RulesHash) throw new Exception("JOIN_IDENTITY");
            native.Restore(joined.Checkpoint.ToByteArray());
            uint frame=joined.Frame;
            var deadline=DateTime.UtcNow.AddSeconds(5);
            while(frame<30 && DateTime.UtcNow<deadline)
            {
                if(!connection.TryPush(out var push)) { await Task.Delay(5); continue; }
                if(push.Code!="OK") throw new Exception(push.Code);
                foreach(var record in push.Records)
                {
                    if(record.Input.Frame!=++frame) throw new Exception("FRAME_GAP");
                    native.Step(record.Input.X,record.Input.Z,(int)record.Input.Skill);
                    if(FrameNative.Hash(native.Save())!=record.Hash) throw new Exception("WINDOWS_DIVERGENCE");
                }
                connection.SendInputs(new FrameInputRequest{BattleId=joined.BattleId,Generation=joined.Generation,
                    Inputs={new FrameCommand{Frame=frame+3,X=1,Skill=3}}});
            }
            if(frame<30) throw new Exception("FRAME_TIMEOUT");
            Console.WriteLine("FRAME_CSHARP_WINDOWS_OK frames="+frame);
        }
        return 0;
    }
}
