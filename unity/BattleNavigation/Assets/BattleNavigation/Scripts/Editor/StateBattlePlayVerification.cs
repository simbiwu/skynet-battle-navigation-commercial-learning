// 作者验证：跨Editor域重载保留验收状态，真实Play读取120 Tick后退出。
#if UNITY_EDITOR
using System;
using System.IO;
using System.Reflection;
using BattleNavigation.StateSync;
using UnityEditor;
using UnityEngine;
namespace BattleNavigation.Client.Editor
{
    [InitializeOnLoad]
    public static class StateBattlePlayVerification
    {
        private const string Active = "StatePlayVerification.Active";
        private const string Finishing = "StatePlayVerification.Finishing";
        private const string Failure = "StatePlayVerification.Failure";
        private const string Started = "StatePlayVerification.Started";
        static StateBattlePlayVerification()
        {
            if (SessionState.GetBool(Active, false)) Register();
        }
        private static void Register()
        {
            Application.logMessageReceived -= Log;
            Application.logMessageReceived += Log;
            EditorApplication.update -= Poll;
            EditorApplication.update += Poll;
        }
        public static void Run()
        {
            StateBattleSceneSetup.Create();
            SessionState.SetBool(Active, true);
            SessionState.SetBool(Finishing, false);
            SessionState.SetString(Failure, "");
            SessionState.SetFloat(Started, (float)EditorApplication.timeSinceStartup);
            Register();
            EditorApplication.isPlaying = true;
        }
        private static void Log(string text, string stack, LogType type)
        {
            if (type == LogType.Exception || type == LogType.Error) SessionState.SetString(Failure, text);
        }
        private static void Poll()
        {
            if (SessionState.GetBool(Finishing, false))
            {
                if (!EditorApplication.isPlaying)
                {
                    SessionState.SetBool(Active, false);
                    EditorApplication.Exit(SessionState.GetString(Failure, "") == "" ? 0 : 1);
                }
                return;
            }
            var controller = UnityEngine.Object.FindObjectOfType<StateBattleController>();
            uint tick = 0;
            string status = "no controller";
            if (controller != null)
            {
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                tick = (uint)typeof(StateBattleController).GetField("lastTick", flags).GetValue(controller);
                status = (string)typeof(StateBattleController).GetField("status", flags).GetValue(controller);
            }
            string failure = SessionState.GetString(Failure, "");
            if (failure == "" && tick < 120 && EditorApplication.timeSinceStartup - SessionState.GetFloat(Started, 0) < 40) return;
            if (tick < 120 && failure == "") failure = "PLAY_TIMEOUT: " + status;
            Directory.CreateDirectory("Build");
            File.WriteAllText("Build/state_play_results.json", "{\"tick\":" + tick +
                ",\"passed\":" + (failure == "" ? "true" : "false") + "}");
            SessionState.SetString(Failure, failure);
            if (failure == "") Debug.Log("STATE_UNITY_PLAY_OK tick=" + tick);
            else Debug.LogError(failure);
            SessionState.SetBool(Finishing, true);
            EditorApplication.isPlaying = false;
        }
    }
}
#endif
