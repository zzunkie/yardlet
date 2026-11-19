// Local stream-json UI fixture. None of the example tool calls run.
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using Map = System.Collections.Generic.Dictionary<string, object>;

internal static class FakeClaude
{
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static readonly StreamWriter Output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
    private static readonly Dictionary<string, Call> Pending = new Dictionary<string, Call>();
    private static string session = Guid.NewGuid().ToString();
    private static bool localScopeNext;
    private static int number;

    private sealed class Call
    {
        public string Id;
        public string Name;
        public Map Input;
    }

    private static Map Obj(params object[] pairs)
    {
        var result = new Map();
        for (int i = 0; i < pairs.Length; i += 2)
            result.Add((string)pairs[i], pairs[i + 1]);
        return result;
    }

    private static object Get(Map obj, string key)
    {
        object value;
        return obj != null && obj.TryGetValue(key, out value) ? value : null;
    }

    private static string Text(Map obj, string key) { return Get(obj, key) as string; }

    private static void Send(Map frame)
    {
        frame["session_id"] = session;
        frame["uuid"] = Guid.NewGuid().ToString();
        Output.WriteLine(Json.Serialize(frame));
    }

    private static void Assistant(params Map[] blocks)
    {
        Send(Obj("type", "assistant", "parent_tool_use_id", null, "message",
            Obj("id", "msg_" + Guid.NewGuid().ToString("N"), "role", "assistant", "type", "message",
                "model", "claude-opus-5-5", "content", blocks)));
    }

    private static void Finish(string summary)
    {
        Assistant(Obj("type", "text", "text", summary));
        Send(Obj("type", "result", "subtype", "success", "is_error", false, "result", summary, "num_turns", 1));
    }

    private static void Request(string name, string description, Map input, string scope)
    {
        string suffix = (++number).ToString();
        string requestId = "qa_request_" + suffix;
        var call = new Call { Id = "toolu_qa_" + suffix, Name = name, Input = input };
        Pending.Add(requestId, call);
        Assistant(Obj("type", "tool_use", "id", call.Id, "name", name, "input", input));
        var request = Obj("subtype", "can_use_tool", "tool_name", name, "tool_use_id", call.Id,
            "title", name, "description", description, "input", input);
        if (scope != null)
            request["permission_suggestions"] = new object[] {
                Obj("type", "addRules", "behavior", "allow", "destination", scope,
                    "rules", new object[] { Obj("toolName", "Bash", "ruleContent", "echo scope") })
            };
        Send(Obj("type", "control_request", "request_id", requestId, "request", request));
    }

    private static void Bash(string description, string command, string scope)
    {
        Request("Bash", description, Obj("command", command, "description", description), scope);
    }

    private static void Begin(string text)
    {
        if (Pending.Count != 0) return;
        Send(Obj("type", "system", "subtype", "init", "tools", new string[] { "Bash", "AskUserQuestion" },
            "model", "claude-opus-5-5", "permissionMode", "default", "apiKeySource", "none"));
        switch (text.Trim().ToUpperInvariant()) {
        case "QA STACK":
            var commands = new List<string>();
            for (int i = 1; i <= 60; i++)
                commands.Add("echo Reviewing checklist item " + i.ToString("00"));
            Bash("Review the complete release checklist", String.Join("\n", commands.ToArray()), null);
            Bash("Review the second checklist", "echo Second checklist", null);
            Bash("Review the final checklist", "echo Final checklist", null);
            break;
        case "QA SCOPE":
            // Claude sends one offer per request. Both choices are checked on their own native request.
            localScopeNext = true;
            Bash("Check the rule for this session", "echo scope", "session");
            break;
        case "QA QUESTION":
            Request("AskUserQuestion", "Choose the report format",
                Obj("questions", new object[] {
                    Obj("header", "Format", "question", "How should the report be formatted?",
                        "multiSelect", false, "options", new object[] {
                            Obj("label", "Summary", "description", "A short overview of the results."),
                            Obj("label", "Detailed", "description", "The results with a line for every check."),
                            Obj("label", "Table", "description", "A compact comparison.")
                        })
                }), null);
            break;
        default:
            Finish("Enter QA STACK, QA SCOPE or QA QUESTION.");
            break;
        }
    }

    private static string UserText(Map message)
    {
        object content = Get(message, "content");
        if (content is string) return (string)content;
        var blocks = content as IEnumerable;
        var result = new StringBuilder();
        if (blocks != null) foreach (object block in blocks)
            if (Text(block as Map, "type") == "text") result.Append(Text(block as Map, "text"));
        return result.ToString();
    }

    private static void Answer(Map envelope)
    {
        string id = Text(envelope, "request_id");
        Call call;
        if (id == null || !Pending.TryGetValue(id, out call)) return;
        Pending.Remove(id);
        var payload = Get(envelope, "response") as Map;
        bool allowed = Text(payload, "behavior") == "allow";
        var updated = Get(payload, "updatedInput") as Map;
        // Echo the actual wire answer to the tool result. The question projection also reads
        // tool_use_result.questions and .answers by the original question text.
        var frame = Obj("type", "user", "parent_tool_use_id", null, "timestamp", DateTime.UtcNow.ToString("o"),
            "message", Obj("role", "user", "content", new object[] {
                Obj("type", "tool_result", "tool_use_id", call.Id, "is_error", !allowed,
                    "content", Json.Serialize(payload == null ? envelope : payload))
            }));
        if (allowed && call.Name == "AskUserQuestion" && Get(updated, "answers") != null)
            frame["tool_use_result"] = Obj("questions", Get(call.Input, "questions"), "answers", Get(updated, "answers"));
        Send(frame);
        if (Pending.Count != 0) return;
        if (localScopeNext) {
            localScopeNext = false;
            Bash("Check the project-local rule", "echo scope", "localSettings");
        } else {
            Finish("The fixture received the response.");
        }
    }

    private static void Control(Map frame)
    {
        string subtype = Text(Get(frame, "request") as Map, "subtype");
        Map result = Obj();
        if (subtype == "initialize")
            result = Obj("commands", new object[0], "models", new object[] {
                Obj("value", "opus", "displayName", "Opus", "description", "QA fixture")
            }, "output_style", "default", "current_permission_mode", "default");
        else if (subtype == "mcp_status")
            result = Obj("mcpServers", new object[0]);
        Send(Obj("type", "control_response", "response",
            Obj("subtype", "success", "request_id", Text(frame, "request_id"), "response", result)));
        if (subtype == "interrupt" && Pending.Count != 0) {
            Pending.Clear();
            localScopeNext = false;
            Finish("The fixture stopped.");
        }
    }

    public static int Main(string[] args)
    {
        Output.AutoFlush = true;
        if (Array.IndexOf(args, "--version") >= 0) {
            Output.WriteLine("2.1.281 (Claude Code)");
            return 0;
        }
        if (args.Length >= 2 && args[0] == "auth" && args[1] == "status") {
            Output.WriteLine(Json.Serialize(Obj("loggedIn", true, "authMethod", "api_key", "apiProvider", "firstParty")));
            return 0;
        }
        if (args.Length >= 2 && args[0] == "plugin" && args[1] == "list") {
            Output.WriteLine("[]");
            return 0;
        }
        if (Array.IndexOf(args, "--input-format") < 0 || Array.IndexOf(args, "stream-json") < 0) return 2;
        foreach (string arg in args) {
            if (arg.StartsWith("--resume=", StringComparison.Ordinal)) session = arg.Substring("--resume=".Length);
            if (arg.StartsWith("--session-id=", StringComparison.Ordinal)) session = arg.Substring("--session-id=".Length);
        }
        using (var input = new StreamReader(Console.OpenStandardInput(), Encoding.UTF8)) {
            string line;
            while ((line = input.ReadLine()) != null) {
                if (String.IsNullOrWhiteSpace(line)) continue;
                var frame = Json.DeserializeObject(line) as Map;
                switch (Text(frame, "type")) {
                case "control_request": Control(frame); break;
                case "control_response": Answer(Get(frame, "response") as Map); break;
                case "user": Begin(UserText(Get(frame, "message") as Map)); break;
                }
            }
        }
        return 0;
    }
}
