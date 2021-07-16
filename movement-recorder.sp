#include <anymap>
#include <sdktools>

enum struct Cmd
{
	int buttons;
	int impulse;
	float angles[3];
	float realangles[3];
	int weapon;
	int subtype;
	int seed;
	int mouse[2];

	float vel[3];
	float pos[3];
	float stamina;
}

bool timescaled[MAXPLAYERS+1];
AnyMap record[MAXPLAYERS+1];
int cursor[MAXPLAYERS+1];
bool recording[MAXPLAYERS+1];
bool playbacking[MAXPLAYERS+1];
bool continuing[MAXPLAYERS+1];

char recordingName[MAXPLAYERS+1][PLATFORM_MAX_PATH];
char playingName[MAXPLAYERS+1][PLATFORM_MAX_PATH];
bool forced[MAXPLAYERS+1];

float startPlayTime[MAXPLAYERS+1] = {-1.0, ...};

ConVar cvDebug;

public void OnPluginStart()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/recordings", path);
	CreateDirectory(path, 0o770);

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientPutInServer(i);

	cvDebug = CreateConVar("rec_debug", "0", "Print debug verbose while recording/playing back");

	RegConsoleCmd("rec_start", Command_Record, "Start recording");
	RegConsoleCmd("rec_stop", Command_RecordStop, "Stop recording");
	RegConsoleCmd("rec_play", Command_Playback, "Play back a saved recording");
	RegConsoleCmd("rec_botplay", Command_BotPlayback, "Play back a saved recording as a bot");

	RegConsoleCmd("rec_playstop", Command_PlaybackStop,
		"Stop record playback");

	RegConsoleCmd("rec_skip", Command_PlaybackSkip,
		"Plays a demo and skips to the last frames without timescaling. " ...
		"This WILL cause desync, for smoother results use rec_playextend");

	RegConsoleCmd("rec_playextend", Command_PlaybackAndContinue,
		"Plays a demo really fast up to the last frames, then starts a new " ...
		"recording that includes the original frames. Saves as <originalname>_ex.txt");
}

public void OnClientPutInServer(int client)
{
	record[client] = new AnyMap();
	recordingName[client][0] = '\0';
	playingName[client][0] = '\0';
	playbacking[client] = false;
	recording[client] = false;
	continuing[client] = false;
	forced[client] = false;
	timescaled[client] = false;
	cursor[client] = 0;
}

public void OnClientDisconnect(int client)
{
	delete record[client];
}

void ExportRecording(int client)
{
	KeyValues kv = new KeyValues("Recorded");

	AnyMapSnapshot snap = record[client].Snapshot();
	for (int i; i < snap.Length; i++)
	{
		int key = snap.GetKey(i);

		Cmd cmd;
		record[client].GetArray(key, cmd, sizeof(cmd));

		char sKey[10];
		IntToString(key, sKey, sizeof(sKey));
		kv.JumpToKey(sKey, true);

		kv.SetNum("buttons", cmd.buttons);
		kv.SetNum("impulse", cmd.impulse);
		kv.SetVector("vel", cmd.vel);
		kv.SetVector("angles", cmd.angles);
		kv.SetVector("realangles", cmd.realangles);
		kv.SetNum("weapon", cmd.weapon);
		kv.SetNum("subtype", cmd.subtype);
		kv.SetNum("seed", cmd.seed);
		kv.SetNum("mouse_x", cmd.mouse[0]);
		kv.SetNum("mouse_y", cmd.mouse[1]);
		kv.SetFloat("stamina", cmd.stamina);
		kv.SetVector("origin", cmd.pos);

		kv.GoBack();
	}

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/recordings/%s.txt", recordingName[client]);
	if (!kv.ExportToFile(path))
		LogError("Failed to save demo to %s", path);
	else
		PrintToServer("Saved demo %s", path);

	delete kv;
}

bool ImportRecording(int client, const char[] name)
{
	KeyValues kv = new KeyValues("Recorded");

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/recordings/%s.txt", name);
	if (!kv.ImportFromFile(path))
	{
		LogError("Failed to import recording %s. File couldn't be found", path);
		delete kv;
		return false;
	}

	if (!kv.GotoFirstSubKey())
	{
		LogError("Failed to import recording %s. File empty or corrupted", path);
		delete kv;
		return false;
	}

	record[client].Clear();

	do
	{
		char sKey[10];
		kv.GetSectionName(sKey, sizeof(sKey));
		int key = StringToInt(sKey);

		Cmd cmd;

		cmd.buttons = kv.GetNum("buttons");
		cmd.impulse = kv.GetNum("impulse");
		kv.GetVector("vel", cmd.vel);
		kv.GetVector("angles", cmd.angles);
		kv.GetVector("realangles", cmd.realangles);
		cmd.weapon = kv.GetNum("weapon");
		cmd.subtype = kv.GetNum("subtype");
		cmd.seed = kv.GetNum("seed");
		cmd.mouse[0] = kv.GetNum("mouse_x");
		cmd.mouse[1] = kv.GetNum("mouse_y");
		cmd.stamina = kv.GetFloat("stamina");
		kv.GetVector("origin", cmd.pos);

		record[client].SetArray(key, cmd, sizeof(cmd));

		PrintToServer("Imported frame %d", key);
	}
	while (kv.GotoNextKey());

	delete kv;
	return true;
}

public Action Command_Record(int client, int args)
{
	if (recording[client])
	{
		ReplyToCommand(client, "Already recording demo");
		return Plugin_Handled;
	}

	char name[PLATFORM_MAX_PATH];
	GetCmdArg(1, name, sizeof(name));

	if (!name[0])
	{
		ReplyToCommand(client, "Missing name");
		return Plugin_Handled;		
	}

	Recording_Start(client, name);
	ReplyToCommand(client, "Recording \"%s\"", name);

	return Plugin_Handled;
}

// public Action Command_PlaybackSkipAll(int client, int args)
// {
// 	forced[client] = true;
// 	cursor[client] = record[client].Size - 100;
// 	ReplyToCommand(client, "Skipping to last 100 frames");
// 	return Plugin_Handled;
// }

public Action Command_PlaybackSkip(int client, int args)
{
	if (!playbacking[client])
	{
		ReplyToCommand(client, "Not playing back demo");
		return Plugin_Handled;
	}

	int skipFrames = GetCmdArgInt(1);

	forced[client] = true;
	cursor[client] += skipFrames;
	ReplyToCommand(client, "Skipping %d frames", skipFrames);
	return Plugin_Handled;
}

public Action Command_PlaybackAndContinue(int client, int args)
{	
	if (args < 1)
	{
		ReplyToCommand(client, "Missing name");
		return Plugin_Handled;
	}

	char name[256];
	GetCmdArg(1, name, sizeof(name));

	if (Playback_Start(client, name))
	{
		continuing[client] = true;
		ServerCommand("host_timescale 15.0");
		timescaled[client] = true;
	}
	return Plugin_Handled;
}

public Action Command_RecordStop(int client, int args)
{
	if (!recording[client])
	{
		ReplyToCommand(client, "Not recording demo");
		return Plugin_Handled;
	}

	Recording_Stop(client);
	return Plugin_Handled;
}

/**
 * Play back demo as the client who issued the command
 */
public Action Command_Playback(int client, int args)
{
	if (recording[client])
	{
		ReplyToCommand(client, "Can't play back demo while recording");
		return Plugin_Handled;
	}

	if (args < 1)
	{
		ReplyToCommand(client, "Usage sm_play <demoname>");
		return Plugin_Handled;
	}

	char recname[256];
	GetCmdArg(1, recname, sizeof(recname));
	Playback_Start(client, recname);

	return Plugin_Handled;
}

/**
 * Play back demo as a bot
 */
public Action Command_BotPlayback(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage sm_botplay <demoname>");
		return Plugin_Handled;
	}

	char recname[256];
	GetCmdArg(1, recname, sizeof(recname));

	for (int i = 1; i <= MaxClients; i++)
	{
		// Skip busy bots
		if (IsClientInGame(i) && IsFakeClient(i) && IsPlayerAlive(i) && !playbacking[i] && !recording[i])
		{
			Playback_Start(i, recname);
			return Plugin_Handled;
		}
	}

	ReplyToCommand(client, "Couldn't find free bot to play demo");
	return Plugin_Handled;
}

/**
 * Stop ongoing playback
 */
public Action Command_PlaybackStop(int client, int args)
{
	playbacking[client] = false;
	return Plugin_Handled;
}

public void OnGameFrame()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;

		if (recording[client] || playbacking[client])
		{
			cursor[client]++;

			if (playbacking[client])
			{
				if (cursor[client] >= record[client].Size)
				{
					Playback_Stop(client);
				}
				else if (record[client].Size - cursor[client] < 50 && timescaled[client])
				{
					timescaled[client] = false;
					ServerCommand("host_timescale 1.0");
				}
			} 
		}
	}
}

void Recording_Start(int client, const char[] name)
{
	record[client].Clear();
	strcopy(recordingName[client], sizeof(recordingName[]), name);
	cursor[client] = 0;	
	recording[client] = true;
}

void Recording_Stop(int client)
{
	recording[client] = false;
	ExportRecording(client);

	record[client].Clear();
	recordingName[client][0] = '\0';
}

bool Playback_Start(int client, const char[] name)
{
	startPlayTime[client] = GetGameTime();

	if (!ImportRecording(client, name))
	{
		return false;
	}
	else
	{
		strcopy(playingName[client], sizeof(playingName[]), name);
		cursor[client] = 0;
		playbacking[client] = true;
		return true;
	}
}

void Playback_Stop(int client)
{
	playbacking[client] = false;

	if (continuing[client])
	{
		continuing[client] = false;
		recording[client] = true;
		Format(recordingName[client], sizeof(recordingName[]), "%s_ex", playingName[client]);
		PrintToServer("Format result was %s", recordingName[client]);
	}

	startPlayTime[client] = -1.0;

	playingName[client][0] = '\0';
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], 
	int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (IsFakeClient(client) && !IsClientSourceTV(client) && !playbacking[client])
		return Plugin_Handled;

	if (recording[client])
	{
		Cmd cmd;

		// We set these 3 on every cmd so we can resume a recording from an arbitrary point 
		// without divergence, we don't actually apply them on the playback outside of the first frame
		cmd.stamina = GetEntPropFloat(client, Prop_Send, "m_flStamina");
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", cmd.vel);
		GetClientAbsOrigin(client, cmd.pos);

		cmd.buttons = buttons;
		cmd.impulse = impulse;
		cmd.vel = vel;
		cmd.angles = angles;
		GetClientEyeAngles(client, cmd.realangles);
		cmd.weapon = weapon;
		cmd.subtype = subtype;
		cmd.seed = seed;
		cmd.mouse = mouse;
		record[client].SetArray(cursor[client], cmd, sizeof(cmd));

		if (cvDebug.BoolValue)
			PrintToServer("Recording frame %d", cursor);
	}

	if (playbacking[client])
	{
		Cmd cmd;
		if (record[client].GetArray(cursor[client], cmd, sizeof(cmd)))
		{
			float realpos[3];
			GetClientAbsOrigin(client, realpos);

			// Force client to desired state if this is the first frame, or we are doing a forced playback
			if (cursor[client] == 1 || forced[client])
			{
				SetEntityHealth(client, 100);
				forced[client] = false;
				SetEntPropFloat(client, Prop_Send, "m_flStamina", cmd.stamina);
				TeleportEntity(client, cmd.pos, cmd.realangles, cmd.vel);
			}
			else
				TeleportEntity(client, .angles=cmd.realangles);
			
			if (cvDebug.BoolValue)
				PrintToServer("Playback elapsed %f", GetGameTime() - startPlayTime[client]);

			buttons = cmd.buttons;
			impulse = cmd.impulse;
			vel = cmd.vel;
			angles = cmd.angles;
			weapon = cmd.weapon;
			subtype = cmd.subtype;
			seed = cmd.seed;
			mouse = cmd.mouse;

			return Plugin_Changed;	
		}	
	}

	return Plugin_Continue;
}
