/*
 * shavit's Timer - Chat
 * by: shavit
 *
 * This file is part of shavit's Timer.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
*/

// Note: For donator perks, give donators a custom flag and then override it to have "shavit_chat".

#include <sourcemod>
#include <clientprefs>
#include <convar_class>

#undef REQUIRE_PLUGIN
#define USES_CHAT_COLORS
#include <shavit>
#include <rtler>

#undef REQUIRE_EXTENSIONS
#include <cstrike>

#define MAGIC_NUMBER 2147483648.0
#define MAXLENGTH_NAME 128
#define MAXLENGTH_TEXT 128
#define MAXLENGTH_MESSAGE 255
#define MAXLENGTH_DISPLAY 192
#define MAXLENGTH_CMESSAGE 16
#define MAXLENGTH_BUFFER 255

enum struct chatranks_cache_t
{
	int iRequire;
	float fFrom;
	float fTo;
	bool bFree;
	bool bEasterEgg;
	bool bRanged;
	bool bPercent;
	char sAdminFlag[32];
	char sName[MAXLENGTH_NAME];
	char sMessage[MAXLENGTH_MESSAGE];
	char sDisplay[MAXLENGTH_DISPLAY];
}

enum
{
	Require_Rank,
	Require_Points,
	Require_WR_Count,
	Require_WR_Rank,
}

// percent, ranged, Require_*
char gA_ChatRankMenuFormatStrings[2][2][4][] = {
	{
		{
			"ChatRanksMenu_Flat",
			"ChatRanksMenu_Points",
			"ChatRanksMenu_WR_Count",
			"ChatRanksMenu_WR_Rank",
		},
		{
			"ChatRanksMenu_Flat_Ranged",
			"ChatRanksMenu_Points_Ranged",
			"ChatRanksMenu_WR_Count_Ranged",
			"ChatRanksMenu_WR_Rank_Ranged",
		}
	},
	{
		{
			"ChatRanksMenu_Percentage",
			"",
			"",
			"ChatRanksMenu_WR_Rank_Percentage",
		},
		{
			"ChatRanksMenu_Percentage_Ranged",
			"",
			"",
			"ChatRanksMenu_WR_Rank_Ranged",
		}
	}
};

#pragma newdecls required
#pragma semicolon 1
#pragma dynamic 131072

// database
Database gH_SQL = null;
char gS_MySQLPrefix[32];

// modules
bool gB_Rankings = false;
bool gB_Stats = false;
bool gB_RTLer = false;

// cvars
Convar gCV_RankingsIntegration = null;
Convar gCV_CustomChat = null;
Convar gCV_Colon = null;

// cache
EngineVersion gEV_Type = Engine_Unknown;

Handle gH_ChatCookie = null;

// -2: auto-assign - user will fallback to this if they're on an index that they don't have access to.
// -1: custom ccname/ccmsg
int gI_ChatSelection[MAXPLAYERS+1];
ArrayList gA_ChatRanks = null;

bool gB_ChangedSinceLogin[MAXPLAYERS+1];

bool gB_CCAccess[MAXPLAYERS+1];

bool gB_NameEnabled[MAXPLAYERS+1];
char gS_CustomName[MAXPLAYERS+1][128];

bool gB_MessageEnabled[MAXPLAYERS+1];
char gS_CustomMessage[MAXPLAYERS+1][16];

// chat procesor
bool gB_Protobuf = false;
bool gB_NewMessage[MAXPLAYERS+1];
StringMap gSM_Messages = null;

char gS_ControlCharacters[][] = {"\x01", "\x02", "\x03", "\x04", "\x05", "\x06", "\x07", "\x08", "\x09",
	"\x0A", "\x0B", "\x0C", "\x0D", "\x0E", "\x0F", "\x10" };

public Plugin myinfo =
{
	name = "[shavit] Chat Processor",
	author = "shavit",
	description = "Custom chat privileges (custom name/message colors), chat processor, and rankings integration.",
	version = SHAVIT_VERSION,
	url = "https://github.com/shavitush/bhoptimer"
}


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("Shavit_GetPlainChatrank", Native_GetPlainChatrank);

	RegPluginLibrary("shavit-chat");

	return APLRes_Success;
}

public void OnPluginStart()
{
	gEV_Type = GetEngineVersion();

	LoadTranslations("shavit-common.phrases");
	LoadTranslations("shavit-chat.phrases");

	RegConsoleCmd("sm_cchelp", Command_CCHelp, "Provides help with setting a custom chat name/message color.");
	RegConsoleCmd("sm_ccname", Command_CCName, "Toggles/sets a custom chat name. Usage: sm_ccname <text> or sm_ccname \"off\" to disable.");
	RegConsoleCmd("sm_ccmsg", Command_CCMessage, "Toggles/sets a custom chat message color. Usage: sm_ccmsg <color> or sm_ccmsg \"off\" to disable.");
	RegConsoleCmd("sm_ccmessage", Command_CCMessage, "Toggles/sets a custom chat message color. Usage: sm_ccmessage <color> or sm_ccmessage \"off\" to disable.");
	RegConsoleCmd("sm_chatrank", Command_ChatRanks, "View a menu with the chat ranks available to you.");
	RegConsoleCmd("sm_chatranks", Command_ChatRanks, "View a menu with the chat ranks available to you.");
	RegConsoleCmd("sm_ranks", Command_Ranks, "View a menu with all the obtainable chat ranks.");

	RegAdminCmd("sm_cclist", Command_CCList, ADMFLAG_CHAT, "Print the custom chat setting of all online players.");
	RegAdminCmd("sm_reloadchatranks", Command_ReloadChatRanks, ADMFLAG_ROOT, "Reloads the chatranks config file.");
	RegAdminCmd("sm_ccadd", Command_CCAdd, ADMFLAG_CHAT, "Grant a user access to using ccname and ccmsg. Usage: sm_ccadd <steamid3>");
	RegAdminCmd("sm_ccdelete", Command_CCDelete, ADMFLAG_CHAT, "Remove access granted to a user with sm_ccadd. Usage: sm_ccdelete <steamid3>");

	gCV_RankingsIntegration = new Convar("shavit_chat_rankings", "1", "Integrate with rankings?\n0 - Disabled\n1 - Enabled", 0, true, 0.0, true, 1.0);
	gCV_CustomChat = new Convar("shavit_chat_customchat", "1", "Allow custom chat names or message colors?\n0 - Disabled\n1 - Enabled (requires chat flag/'shavit_chat' override or granted access with sm_ccadd)\n2 - Allow use by everyone", 0, true, 0.0, true, 2.0);
	gCV_Colon = new Convar("shavit_chat_colon", ":", "String to use as the colon when messaging.");

	Convar.AutoExecConfig();

	gSM_Messages = new StringMap();
	gB_Protobuf = (GetUserMessageType() == UM_Protobuf);
	HookUserMessage(GetUserMessageId("SayText2"), Hook_SayText2, true);

	gH_ChatCookie = RegClientCookie("shavit_chat_selection", "Chat settings", CookieAccess_Protected);
	gA_ChatRanks = new ArrayList(sizeof(chatranks_cache_t));

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i))
		{
			if(AreClientCookiesCached(i))
			{
				OnClientCookiesCached(i);
			}
		}
	}

	gB_RTLer = LibraryExists("rtler");

	SQL_DBConnect();
}

public void OnMapStart()
{
	if(!LoadChatConfig())
	{
		SetFailState("Could not load the chat configuration file. Make sure it exists (addons/sourcemod/configs/shavit-chat.cfg) and follows the proper syntax!");
	}

	if(!LoadChatSettings())
	{
		SetFailState("Could not load the chat settings file. Make sure it exists (addons/sourcemod/configs/shavit-chatsettings.cfg) and follows the proper syntax!");
	}
}

bool LoadChatConfig()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, PLATFORM_MAX_PATH, "configs/shavit-chat.cfg");

	KeyValues kv = new KeyValues("shavit-chat");
	
	if(!kv.ImportFromFile(sPath) || !kv.GotoFirstSubKey())
	{
		delete kv;

		return false;
	}

	gA_ChatRanks.Clear();

	do
	{
		chatranks_cache_t chat_title;
		char sRanks[32];
		kv.GetString("ranks", sRanks, 32, "0");

		if(sRanks[0] == 'p')
		{	
			chat_title.iRequire = Require_Points;
		}
		else if(sRanks[0] == 'w')
		{
			chat_title.iRequire = Require_WR_Count;
		}
		else if(sRanks[0] == 'W')
		{
			chat_title.iRequire = Require_WR_Rank;
		}
		else
		{
			chat_title.iRequire = Require_Rank;
		}

		chat_title.bPercent = (StrContains(sRanks, "%") != -1);

		ReplaceString(sRanks, 32, "w", "");
		ReplaceString(sRanks, 32, "W", "");
		ReplaceString(sRanks, 32, "p", "");
		ReplaceString(sRanks, 32, "%%", "");

		if(StrContains(sRanks, "-") != -1)
		{
			char sExplodedString[2][16];
			ExplodeString(sRanks, "-", sExplodedString, 2, 64);
			chat_title.fFrom = StringToFloat(sExplodedString[0]);
			chat_title.fTo = StringToFloat(sExplodedString[1]);
			chat_title.bRanged = true;
		}
		else
		{
			float fRank = StringToFloat(sRanks);

			chat_title.fFrom = fRank;

			if (chat_title.iRequire == Require_WR_Count || chat_title.iRequire == Require_Points)
			{
				chat_title.fTo = MAGIC_NUMBER;
			}
			else
			{
				chat_title.fTo = fRank;
			}
		}

		if(chat_title.bPercent)
		{
			if(chat_title.iRequire == Require_WR_Count)
			{
				LogError("shavit chatranks can't use WR count & percentage in the same tag"); // TODO: ???
			}
			else if(chat_title.iRequire == Require_Points)
			{
				LogError("shavit chatranks can't use points & percentage in the same tag"); // TODO: ???
			}
		}
		
		chat_title.bFree = view_as<bool>(kv.GetNum("free", false));
		chat_title.bEasterEgg = view_as<bool>(kv.GetNum("easteregg", false));
		
		kv.GetString("name", chat_title.sName, MAXLENGTH_NAME, "{name}");
		kv.GetString("message", chat_title.sMessage, MAXLENGTH_MESSAGE, "");
		kv.GetString("display", chat_title.sDisplay, MAXLENGTH_DISPLAY, "");
		kv.GetString("flag", chat_title.sAdminFlag, 32, "");

		if(strlen(chat_title.sDisplay) > 0)
		{
			gA_ChatRanks.PushArray(chat_title);
		}
	}

	while(kv.GotoNextKey());

	delete kv;

	return true;
}

bool LoadChatSettings()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, PLATFORM_MAX_PATH, "configs/shavit-chatsettings.cfg");

	KeyValues kv = new KeyValues("shavit-chat");
	
	if(!kv.ImportFromFile(sPath))
	{
		delete kv;

		return false;
	}

	gSM_Messages.Clear();
	bool failed;

	if(gEV_Type == Engine_CSS)
	{
		failed = !kv.JumpToKey("CS:S");
	}

	else if(gEV_Type == Engine_CSGO)
	{
		failed = !kv.JumpToKey("CS:GO");
	}

	if(gEV_Type == Engine_TF2)
	{
		failed = !kv.JumpToKey("TF2");
	}

	if(failed || !kv.GotoFirstSubKey(false))
	{
		SetFailState("Invalid \"configs/shavit-chatsettings.cfg\" file, or the game section is missing");
	}

	do
	{
		char sSection[32];
		kv.GetSectionName(sSection, 32);

		char sText[MAXLENGTH_BUFFER];
		kv.GetString(NULL_STRING, sText, MAXLENGTH_BUFFER);

		gSM_Messages.SetString(sSection, sText);
	}

	while(kv.GotoNextKey(false));

	delete kv;

	return true;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if(1 <= client <= MaxClients)
	{
		gB_NewMessage[client] = true;
	}

	return Plugin_Continue;
}

void ReplaceFormats(char[] formatting, int maxlen, char[] name, char[] colon, char[] text)
{
	FormatColors(formatting, maxlen, true, false);
	FormatRandom(formatting, maxlen);
	ReplaceString(formatting, maxlen, "{name}", name);
	ReplaceString(formatting, maxlen, "{def}", "\x01");
	ReplaceString(formatting, maxlen, "{colon}", colon);
	ReplaceString(formatting, maxlen, "{msg}", text);
}

public Action Hook_SayText2(UserMsg msg_id, any msg, const int[] players, int playersNum, bool reliable, bool init)
{
	int client = 0;
	char sMessage[32];
	char sOriginalName[MAXLENGTH_NAME];
	char sOriginalText[MAXLENGTH_TEXT];

	if(gB_Protobuf)
	{
		Protobuf pbmsg = UserMessageToProtobuf(msg);
		client = pbmsg.ReadInt("ent_idx");
		pbmsg.ReadString("msg_name", sMessage, 32);
		pbmsg.ReadString("params", sOriginalName, MAXLENGTH_NAME, 0);
		pbmsg.ReadString("params", sOriginalText, MAXLENGTH_TEXT, 1);
	}

	else
	{
		BfRead bfmsg = UserMessageToBfRead(msg);
		client = bfmsg.ReadByte();
		bfmsg.ReadByte(); // chat parameter
		bfmsg.ReadString(sMessage, 32);
		bfmsg.ReadString(sOriginalName, MAXLENGTH_NAME);
		bfmsg.ReadString(sOriginalText, MAXLENGTH_TEXT);
	}

	if(client == 0)
	{
		return Plugin_Continue;
	}

	if(!gB_NewMessage[client])
	{
		return Plugin_Stop;
	}

	gB_NewMessage[client] = false;

	char sTextFormatting[MAXLENGTH_BUFFER];

	// not a hooked message
	if(!gSM_Messages.GetString(sMessage, sTextFormatting, MAXLENGTH_BUFFER))
	{
		return Plugin_Continue;
	}

	Format(sTextFormatting, MAXLENGTH_BUFFER, "\x01%s", sTextFormatting);

	// remove control characters
	for(int i = 0; i < sizeof(gS_ControlCharacters); i++)
	{
		ReplaceString(sOriginalName, MAXLENGTH_NAME, gS_ControlCharacters[i], "");
		ReplaceString(sOriginalText, MAXLENGTH_TEXT, gS_ControlCharacters[i], "");
	}

	// fix an exploit that breaks chat colors in cs:s
	while(ReplaceString(sOriginalText, MAXLENGTH_TEXT, "   ", " ") > 0) { }

	char sName[MAXLENGTH_NAME];
	char sCMessage[MAXLENGTH_CMESSAGE];
	
	if(HasCustomChat(client) && gI_ChatSelection[client] == -1)
	{
		if(gB_NameEnabled[client])
		{
			strcopy(sName, MAXLENGTH_NAME, gS_CustomName[client]);
		}

		if(gB_MessageEnabled[client])
		{
			strcopy(sCMessage, MAXLENGTH_CMESSAGE, gS_CustomMessage[client]);
		}
	}

	else
	{
		GetPlayerChatSettings(client, sName, sCMessage);
	}

	if(strlen(sName) > 0)
	{
		FormatChat(client, sName, MAXLENGTH_NAME);
		strcopy(sOriginalName, MAXLENGTH_NAME, sName);
	}

	if(strlen(sMessage) > 0)
	{
		FormatChat(client, sCMessage, MAXLENGTH_CMESSAGE);

		char sFixedMessage[MAXLENGTH_MESSAGE];

		// support RTL messages
		if(gB_RTLer && RTLify(sFixedMessage, MAXLENGTH_MESSAGE, sOriginalText) > 0)
		{
			TrimString(sOriginalText);
			Format(sOriginalText, MAXLENGTH_MESSAGE, "%s%s", sFixedMessage, sCMessage);
		}

		else
		{
			Format(sOriginalText, MAXLENGTH_MESSAGE, "%s%s", sCMessage, sOriginalText);
		}
	}

	char sColon[MAXLENGTH_CMESSAGE];
	gCV_Colon.GetString(sColon, MAXLENGTH_CMESSAGE);

	ReplaceFormats(sTextFormatting, MAXLENGTH_BUFFER, sName, sColon, sOriginalText);

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientSerial(client)); // client serial
	pack.WriteCell(StrContains(sMessage, "_All") != -1); // all chat
	pack.WriteString(sTextFormatting); // text
	RequestFrame(Frame_SendText, pack);

	return Plugin_Stop;
}

void Frame_SendText(DataPack pack)
{
	pack.Reset();
	int serial = pack.ReadCell();
	bool allchat = pack.ReadCell();
	char sText[MAXLENGTH_BUFFER];
	pack.ReadString(sText, MAXLENGTH_BUFFER);
	delete pack;

	int client = GetClientFromSerial(serial);

	if(client == 0)
	{
		return;
	}

	int team = GetClientTeam(client);
	int clients[MAXPLAYERS+1];
	int count = 0;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientConnected(i))
		{
			continue;
		}

		if(IsClientSourceTV(i) || IsClientReplay(i) || // sourcetv?
			(IsClientInGame(i) && (allchat || GetClientTeam(i) == team)))
		{
			clients[count++] = i;
		}
	}

	// should never happen
	if(count == 0)
	{
		return;
	}
	
	Handle hSayText2 = StartMessage("SayText2", clients, count, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);

	if(hSayText2 == null)
	{
		return;
	}

	if(gB_Protobuf)
	{
		// show colors in cs:go
		Format(sText, MAXLENGTH_BUFFER, " %s", sText);

		Protobuf pbmsg = UserMessageToProtobuf(hSayText2);
		pbmsg.SetInt("ent_idx", client);
		pbmsg.SetBool("chat", true);
		pbmsg.SetString("msg_name", sText);
		
		// needed to not crash
		for(int i = 1; i <= 4; i++)
		{
			pbmsg.AddString("params", "");
		}
	}

	else
	{
		BfWrite bfmsg = UserMessageToBfWrite(hSayText2);
		bfmsg.WriteByte(client);
		bfmsg.WriteByte(true);
		bfmsg.WriteString(sText);
	}

	EndMessage();
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "rtler"))
	{
		gB_RTLer = true;
	}

	else if(StrEqual(name, "shavit-rankings"))
	{
		gB_Rankings = true;
	}

	else if(StrEqual(name, "shavit-stats"))
	{
		gB_Stats = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "rtler"))
	{
		gB_RTLer = false;
	}

	else if(StrEqual(name, "shavit-rankings"))
	{
		gB_Rankings = false;
	}

	else if(StrEqual(name, "shavit-stats"))
	{
		gB_Stats = false;
	}
}

public void OnClientCookiesCached(int client)
{
	char sChatSettings[8];
	GetClientCookie(client, gH_ChatCookie, sChatSettings, 8);

	if(strlen(sChatSettings) == 0)
	{
		SetClientCookie(client, gH_ChatCookie, "-2");
		gI_ChatSelection[client] = -2;
	}

	else
	{
		gI_ChatSelection[client] = StringToInt(sChatSettings);
	}
}

public void OnClientPutInServer(int client)
{
	gB_CCAccess[client] = false;

	gB_NameEnabled[client] = true;
	strcopy(gS_CustomName[client], 128, "{team}{name}");

	gB_MessageEnabled[client] = true;
	strcopy(gS_CustomMessage[client], 128, "{default}");
}

public void OnClientDisconnect(int client)
{
	if(HasCustomChat(client))
	{
		SaveToDatabase(client);
	}
}

public void OnClientPostAdminCheck(int client)
{
	LoadFromDatabase(client);
}

public Action Command_CCHelp(int client, int args)
{
	if(client == 0)
	{
		ReplyToCommand(client, "%t", "NoConsole");

		return Plugin_Handled;
	}

	Shavit_PrintToChat(client, "%T", "CheckConsole", client);

	PrintToConsole(client, "%T\n\n%T\n\n%T\n",
		"CCHelp_Intro", client,
		"CCHelp_Generic", client,
		"CCHelp_GenericVariables", client);

	if(IsSource2013(gEV_Type))
	{
		PrintToConsole(client, "%T\n\n%T",
			"CCHelp_CSS_1", client,
			"CCHelp_CSS_2", client);
	}

	else
	{
		PrintToConsole(client, "%T", "CCHelp_CSGO_1", client);
	}

	return Plugin_Handled;
}

public Action Command_CCName(int client, int args)
{
	if(client == 0)
	{
		ReplyToCommand(client, "%t", "NoConsole");

		return Plugin_Handled;
	}

	if(!HasCustomChat(client))
	{
		Shavit_PrintToChat(client, "%T", "NoCommandAccess", client);

		return Plugin_Handled;
	}

	char sArgs[128];
	GetCmdArgString(sArgs, 128);
	TrimString(sArgs);

	if(args == 0 || strlen(sArgs) == 0)
	{
		Shavit_PrintToChat(client, "%T", "ArgumentsMissing", client, "sm_ccname <text>");
		Shavit_PrintToChat(client, "%T", "ChatCurrent", client, gS_CustomName[client]);

		return Plugin_Handled;
	}

	else if(StrEqual(sArgs, "off"))
	{
		Shavit_PrintToChat(client, "%T", "NameOff", client, sArgs);

		gB_NameEnabled[client] = false;

		return Plugin_Handled;
	}

	Shavit_PrintToChat(client, "%T", "ChatUpdated", client);

	if(!StrEqual(gS_CustomName[client], sArgs))
	{
		gB_ChangedSinceLogin[client] = true;
	}

	gB_NameEnabled[client] = true;
	strcopy(gS_CustomName[client], 128, sArgs);

	return Plugin_Handled;
}

public Action Command_CCMessage(int client, int args)
{
	if(client == 0)
	{
		ReplyToCommand(client, "%t", "NoConsole");

		return Plugin_Handled;
	}

	if(!HasCustomChat(client))
	{
		Shavit_PrintToChat(client, "%T", "NoCommandAccess", client);

		return Plugin_Handled;
	}

	char sArgs[32];
	GetCmdArgString(sArgs, 32);
	TrimString(sArgs);

	if(args == 0 || strlen(sArgs) == 0)
	{
		Shavit_PrintToChat(client, "%T", "ArgumentsMissing", client, "sm_ccmsg <text>");
		Shavit_PrintToChat(client, "%T", "ChatCurrent", client, gS_CustomMessage[client]);

		return Plugin_Handled;
	}

	else if(StrEqual(sArgs, "off"))
	{
		Shavit_PrintToChat(client, "%T", "MessageOff", client, sArgs);

		gB_MessageEnabled[client] = false;

		return Plugin_Handled;
	}

	Shavit_PrintToChat(client, "%T", "ChatUpdated", client);

	if(!StrEqual(gS_CustomMessage[client], sArgs))
	{
		gB_ChangedSinceLogin[client] = true;
	}

	gB_MessageEnabled[client] = true;
	strcopy(gS_CustomMessage[client], 16, sArgs);

	return Plugin_Handled;
}

public Action Command_ChatRanks(int client, int args)
{
	if(client == 0)
	{
		return Plugin_Handled;
	}

	return ShowChatRanksMenu(client, 0);
}

Action ShowChatRanksMenu(int client, int item)
{
	Menu menu = new Menu(MenuHandler_ChatRanks);
	menu.SetTitle("%T\n ", "SelectChatRank", client);

	char sDisplay[MAXLENGTH_DISPLAY];
	FormatEx(sDisplay, MAXLENGTH_DISPLAY, "%T\n ", "AutoAssign", client);
	menu.AddItem("-2", sDisplay, (gI_ChatSelection[client] == -2)? ITEMDRAW_DISABLED:ITEMDRAW_DEFAULT);

	if(HasCustomChat(client))
	{
		FormatEx(sDisplay, MAXLENGTH_DISPLAY, "%T\n ", "CustomChat", client);
		menu.AddItem("-1", sDisplay, (gI_ChatSelection[client] == -1)? ITEMDRAW_DISABLED:ITEMDRAW_DEFAULT);
	}

	int iLength = gA_ChatRanks.Length;

	for(int i = 0; i < iLength; i++)
	{
		if(!HasRankAccess(client, i))
		{
			continue;
		}

		chatranks_cache_t cache;
		gA_ChatRanks.GetArray(i, cache, sizeof(chatranks_cache_t));

		char sMenuDisplay[MAXLENGTH_DISPLAY];
		strcopy(sMenuDisplay, MAXLENGTH_DISPLAY, cache.sDisplay);
		ReplaceString(sMenuDisplay, MAXLENGTH_DISPLAY, "<n>", "\n");
		StrCat(sMenuDisplay, MAXLENGTH_DISPLAY, "\n "); // to add spacing between each entry

		char sInfo[8];
		IntToString(i, sInfo, 8);

		menu.AddItem(sInfo, sMenuDisplay, (gI_ChatSelection[client] == i)? ITEMDRAW_DISABLED:ITEMDRAW_DEFAULT);
	}

	menu.ExitButton = true;
	menu.DisplayAt(client, item, MENU_TIME_FOREVER);

	return Plugin_Handled;
}

public int MenuHandler_ChatRanks(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);

		int iChoice = StringToInt(sInfo);

		gI_ChatSelection[param1] = iChoice;
		SetClientCookie(param1, gH_ChatCookie, sInfo);

		Shavit_PrintToChat(param1, "%T", "ChatUpdated", param1);
		ShowChatRanksMenu(param1, GetMenuSelectionPosition());
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}
}

public Action Command_Ranks(int client, int args)
{
	if(client == 0)
	{
		return Plugin_Handled;
	}

	return ShowRanksMenu(client, 0);
}

Action ShowRanksMenu(int client, int item)
{
	Menu menu = new Menu(MenuHandler_Ranks);
	menu.SetTitle("%T\n ", "ChatRanksMenu", client);

	int iLength = gA_ChatRanks.Length;

	for(int i = 0; i < iLength; i++)
	{
		chatranks_cache_t cache;
		gA_ChatRanks.GetArray(i, cache, sizeof(chatranks_cache_t));

		char sFlag[32];
		strcopy(sFlag, 32, cache.sAdminFlag);

		bool bFlagAccess = false;
		int iSize = strlen(sFlag);

		if(iSize == 0)
		{
			bFlagAccess = true;
		}

		else if(iSize == 1)
		{
			AdminFlag afFlag = view_as<AdminFlag>(0);
			
			if(FindFlagByChar(sFlag[0], afFlag))
			{
				bFlagAccess = GetAdminFlag(GetUserAdmin(client), afFlag);
			}
		}

		else
		{
			bFlagAccess = CheckCommandAccess(client, sFlag, 0, true);
		}

		if(cache.bEasterEgg || !bFlagAccess)
		{
			continue;
		}

		char sDisplay[MAXLENGTH_DISPLAY];
		strcopy(sDisplay, MAXLENGTH_DISPLAY, cache.sDisplay);
		ReplaceString(sDisplay, MAXLENGTH_DISPLAY, "<n>", "\n");

		char sExplodedString[2][32];
		ExplodeString(sDisplay, "\n", sExplodedString, 2, 64);

		FormatEx(sDisplay, MAXLENGTH_DISPLAY, "%s\n ", sExplodedString[0]);

		char sRequirements[64];

		if(!cache.bFree)
		{
			if(cache.fFrom == 0.0 && cache.fTo == 0.0)
			{
				FormatEx(sRequirements, 64, "%T", "ChatRanksMenu_Unranked", client);
			}
			else
			{
				char sTranslation[64];
				strcopy(sTranslation, sizeof(sTranslation), gA_ChatRankMenuFormatStrings[cache.bPercent?1:0][cache.bRanged?1:0][cache.iRequire]);

				if (!cache.bRanged && !cache.bPercent && cache.fFrom == 1.0)
				{
					StrCat(sTranslation, sizeof(sTranslation), "_1");
				}

				FormatEx(sRequirements, 64, "%T", sTranslation, client, cache.fFrom, cache.fTo, '%', '%');
			}
		}

		StrCat(sDisplay, MAXLENGTH_DISPLAY, sRequirements);
		StrCat(sDisplay, MAXLENGTH_DISPLAY, "\n ");

		char sInfo[8];
		IntToString(i, sInfo, 8);

		menu.AddItem(sInfo, sDisplay);
	}

	// why even
	if(menu.ItemCount == 0)
	{
		menu.AddItem("-1", "Nothing");
	}

	menu.ExitButton = true;
	menu.DisplayAt(client, item, MENU_TIME_FOREVER);

	return Plugin_Handled;
}

public int MenuHandler_Ranks(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);

		PreviewChat(param1, StringToInt(sInfo));
		ShowRanksMenu(param1, GetMenuSelectionPosition());
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}
}

void PreviewChat(int client, int rank)
{
	char sTextFormatting[MAXLENGTH_BUFFER];
	gSM_Messages.GetString((gEV_Type != Engine_TF2)? "Cstrike_Chat_All":"TF_Chat_All", sTextFormatting, MAXLENGTH_BUFFER);
	Format(sTextFormatting, MAXLENGTH_BUFFER, "\x01%s", sTextFormatting);

	char sOriginalName[MAXLENGTH_NAME];
	GetClientName(client, sOriginalName, MAXLENGTH_NAME);

	// remove control characters
	for(int i = 0; i < sizeof(gS_ControlCharacters); i++)
	{
		ReplaceString(sOriginalName, MAXLENGTH_NAME, gS_ControlCharacters[i], "");
	}

	chatranks_cache_t cache;
	gA_ChatRanks.GetArray(rank, cache, sizeof(chatranks_cache_t));

	char sName[MAXLENGTH_NAME];
	strcopy(sName, MAXLENGTH_NAME, cache.sName);

	char sCMessage[MAXLENGTH_CMESSAGE];
	strcopy(sCMessage, MAXLENGTH_CMESSAGE, cache.sMessage);

	FormatChat(client, sName, MAXLENGTH_NAME);
	strcopy(sOriginalName, MAXLENGTH_NAME, sName);

	FormatChat(client, sCMessage, MAXLENGTH_CMESSAGE);

	char sSampleText[MAXLENGTH_MESSAGE];
	FormatEx(sSampleText, MAXLENGTH_MESSAGE, "%s%T", sCMessage, "ChatRanksMenu_SampleText", client);

	char sColon[MAXLENGTH_CMESSAGE];
	gCV_Colon.GetString(sColon, MAXLENGTH_CMESSAGE);

	ReplaceFormats(sTextFormatting, MAXLENGTH_BUFFER, sName, sColon, sSampleText);

	Handle hSayText2 = StartMessageOne("SayText2", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);

	if(hSayText2 != null)
	{
		if(gB_Protobuf)
		{
			// show colors in cs:go
			Format(sTextFormatting, MAXLENGTH_BUFFER, " %s", sTextFormatting);

			Protobuf pbmsg = UserMessageToProtobuf(hSayText2);
			pbmsg.SetInt("ent_idx", client);
			pbmsg.SetBool("chat", true);
			pbmsg.SetString("msg_name", sTextFormatting);
			
			for(int i = 1; i <= 4; i++)
			{
				pbmsg.AddString("params", "");
			}
		}

		else
		{
			BfWrite bfmsg = UserMessageToBfWrite(hSayText2);
			bfmsg.WriteByte(client);
			bfmsg.WriteByte(true);
			bfmsg.WriteString(sTextFormatting);
		}
	}

	EndMessage();
}

bool HasCustomChat(int client)
{
	return (gCV_CustomChat.IntValue > 0 && (CheckCommandAccess(client, "shavit_chat", ADMFLAG_CHAT) || gCV_CustomChat.IntValue == 2 || gB_CCAccess[client]));
}

bool HasRankAccess(int client, int rank)
{
	if(rank == -2 ||
		(rank == -1 && HasCustomChat(client)))
	{
		return true;
	}

	else if(!(0 <= rank <= (gA_ChatRanks.Length - 1)))
	{
		return false;
	}

	chatranks_cache_t cache;
	gA_ChatRanks.GetArray(rank, cache, sizeof(chatranks_cache_t));

	char sFlag[32];
	strcopy(sFlag, 32, cache.sAdminFlag);

	bool bFlagAccess = false;
	int iSize = strlen(sFlag);

	if(iSize == 0)
	{
		bFlagAccess = true;
	}

	else if(iSize == 1)
	{
		AdminFlag afFlag = view_as<AdminFlag>(0);
		
		if(FindFlagByChar(sFlag[0], afFlag))
		{
			bFlagAccess = GetAdminFlag(GetUserAdmin(client), afFlag);
		}
	}

	else
	{
		bFlagAccess = CheckCommandAccess(client, sFlag, 0, true);
	}

	if(!bFlagAccess)
	{
		return false;
	}

	if(cache.bFree)
	{
		return true;
	}

	if(/*!gB_Rankings ||*/ !gCV_RankingsIntegration.BoolValue)
	{
		return false;
	}

	if ((!gB_Rankings && (cache.iRequire == Require_Rank || cache.iRequire == Require_Points))
	|| (!gB_Stats && (cache.iRequire == Require_WR_Count || cache.iRequire == Require_WR_Rank)))
	{
		return false;
	}

	float fVal, fTotal;

	switch (cache.iRequire)
	{
		case Require_Rank:
		{
			fVal = float(Shavit_GetRank(client));
			fTotal = float(Shavit_GetRankedPlayers());
		}
		case Require_Points:
		{
			fVal = Shavit_GetPoints(client);
		}
		case Require_WR_Count:
		{
			fVal = float(Shavit_GetWRCount(client));
		}
		case Require_WR_Rank:
		{
			fVal = float(Shavit_GetWRHolderRank(client));
			fTotal = float(Shavit_GetWRHolders());
		}
	}

	if(!cache.bPercent)
	{
		if(cache.fFrom <= fVal <= cache.fTo)
		{
			return true;
		}
	}
	else
	{
		if(fTotal == 0.0)
		{
			fTotal = 1.0;
		}

		if(fVal == 1.0 && (fTotal == 1.0 || cache.fFrom == cache.fTo))
		{
			return true;
		}

		float fPercentile = (fVal / fTotal) * 100.0;
		
		if(cache.fFrom <= fPercentile <= cache.fTo)
		{
			return true;
		}
	}

	return false;
}

void GetPlayerChatSettings(int client, char[] name, char[] message)
{
	int iRank = gI_ChatSelection[client];
	
	if(!HasRankAccess(client, iRank))
	{
		iRank = -2;
	}

	int iLength = gA_ChatRanks.Length;

	// if we auto-assign, start looking for an available rank starting from index 0
	if(iRank == -2)
	{
		for(int i = 0; i < iLength; i++)
		{
			if(HasRankAccess(client, i))
			{
				iRank = i;

				break;
			}
		}
	}

	if(0 <= iRank <= (iLength - 1))
	{
		chatranks_cache_t cache;
		gA_ChatRanks.GetArray(iRank, cache, sizeof(chatranks_cache_t));

		strcopy(name, MAXLENGTH_NAME, cache.sName);
		strcopy(message, MAXLENGTH_NAME, cache.sMessage);
	}
}

public Action Command_CCList(int client, int args)
{
	ReplyToCommand(client, "%T", "CheckConsole", client);

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && !IsFakeClient(i) && HasCustomChat(client))
		{
			PrintToConsole(client, "%N (%d/#%d) (name: \"%s\"; message: \"%s\")", i, i, GetClientUserId(i), gS_CustomName[i], gS_CustomMessage[i]);
		}
	}

	return Plugin_Handled;
}

public Action Command_ReloadChatRanks(int client, int args)
{
	if(LoadChatConfig())
	{
		ReplyToCommand(client, "Reloaded chatranks config.");
	}

	return Plugin_Handled;
}

public Action Command_CCAdd(int client, int args)
{
	if (args == 0)
	{
		ReplyToCommand(client, "Missing steamid3");
		return Plugin_Handled;
	}

	char sArgString[32];
	GetCmdArgString(sArgString, 32);

	ReplaceString(sArgString, 32, "[U:1:", "");
	ReplaceString(sArgString, 32, "]", "");

	int iSteamID = StringToInt(sArgString);

	if (iSteamID == 0)
	{
		ReplyToCommand(client, "Invalid steamid");
		return Plugin_Handled;
	}

	char sQuery[128];
	FormatEx(sQuery, sizeof(sQuery), "REPLACE INTO %schat (auth, ccaccess) VALUES (%d, 1);", gS_MySQLPrefix, iSteamID);
	gH_SQL.Query(SQL_UpdateUser_Callback, sQuery, 0, DBPrio_Low);

	for(int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && GetSteamAccountID(i) == iSteamID)
		{
			gB_CCAccess[i] = true;
		}
	}

	ReplyToCommand(client, "Added CC access for [U:1:%d]", iSteamID);

	return Plugin_Handled;
}

public Action Command_CCDelete(int client, int args)
{
	if (args == 0)
	{
		ReplyToCommand(client, "Missing steamid3");
		return Plugin_Handled;
	}

	char sArgString[32];
	GetCmdArgString(sArgString, 32);

	ReplaceString(sArgString, 32, "[U:1:", "");
	ReplaceString(sArgString, 32, "]", "");

	int iSteamID = StringToInt(sArgString);

	if (iSteamID == 0)
	{
		ReplyToCommand(client, "Invalid steamid");
		return Plugin_Handled;
	}

	char sQuery[128];
	FormatEx(sQuery, sizeof(sQuery), "UPDATE %schat SET ccaccess = 0 WHERE auth = %d;", gS_MySQLPrefix, iSteamID);
	gH_SQL.Query(SQL_UpdateUser_Callback, sQuery, 0, DBPrio_Low);

	for(int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && GetSteamAccountID(i) == iSteamID)
		{
			gB_CCAccess[i] = false;
		}
	}

	ReplyToCommand(client, "Deleted CC access for [U:1:%d]", iSteamID);

	return Plugin_Handled;
}

void FormatColors(char[] buffer, int size, bool colors, bool escape)
{
	if(colors)
	{
		for(int i = 0; i < sizeof(gS_GlobalColorNames); i++)
		{
			ReplaceString(buffer, size, gS_GlobalColorNames[i], gS_GlobalColors[i]);
		}

		if(gEV_Type == Engine_CSGO)
		{
			for(int i = 0; i < sizeof(gS_CSGOColorNames); i++)
			{
				ReplaceString(buffer, size, gS_CSGOColorNames[i], gS_CSGOColors[i]);
			}
		}

		ReplaceString(buffer, size, "^", "\x07");
		ReplaceString(buffer, size, "{RGB}", "\x07");
		ReplaceString(buffer, size, "&", "\x08");
		ReplaceString(buffer, size, "{RGBA}", "\x08");
	}

	if(escape)
	{
		ReplaceString(buffer, size, "%%", "");
	}
}

void FormatRandom(char[] buffer, int size)
{
	char temp[8];

	do
	{
		if(IsSource2013(gEV_Type))
		{
			FormatEx(temp, 8, "\x07%06X", GetRandomInt(0, 0xFFFFFF));
		}

		else
		{
			strcopy(temp, 8, gS_CSGOColors[GetRandomInt(0, sizeof(gS_CSGOColors) - 1)]);
		}
	}

	while(ReplaceStringEx(buffer, size, "{rand}", temp) > 0);
}

void FormatChat(int client, char[] buffer, int size)
{
	FormatColors(buffer, size, true, true);
	FormatRandom(buffer, size);

	char temp[32];

	if(gEV_Type != Engine_TF2)
	{
		CS_GetClientClanTag(client, temp, 32);
		ReplaceString(buffer, size, "{clan}", temp);
	}

	if(gB_Rankings)
	{
		int iRank = Shavit_GetRank(client);
		IntToString(iRank, temp, 32);
		ReplaceString(buffer, size, "{rank}", temp);

		int iRanked = Shavit_GetRankedPlayers();

		if(iRanked == 0)
		{
			iRanked = 1;
		}

		float fPercentile = (float(iRank) / iRanked) * 100.0;
		FormatEx(temp, 32, "%.01f", fPercentile);
		ReplaceString(buffer, size, "{rank1}", temp);

		FormatEx(temp, 32, "%.02f", fPercentile);
		ReplaceString(buffer, size, "{rank2}", temp);

		FormatEx(temp, 32, "%.03f", fPercentile);
		ReplaceString(buffer, size, "{rank3}", temp);

		FormatEx(temp, 32, "%0.f", Shavit_GetPoints(client));
		ReplaceString(buffer, size, "{pts}", temp);
	}

	FormatEx(temp, 32, "%d", Shavit_GetWRHolderRank(client));
	ReplaceString(buffer, size, "{wrrank}", temp);

	FormatEx(temp, 32, "%d", Shavit_GetWRCount(client));
	ReplaceString(buffer, size, "{wrs}", temp);

	GetClientName(client, temp, 32);
	ReplaceString(buffer, size, "{name}", temp);
}

void SQL_DBConnect()
{
	GetTimerSQLPrefix(gS_MySQLPrefix, 32);
	gH_SQL = GetTimerDatabaseHandle();

	char sQuery[512];

	if(IsMySQLDatabase(gH_SQL))
	{
		FormatEx(sQuery, 512,
			"CREATE TABLE IF NOT EXISTS `%schat` (`auth` INT NOT NULL, `name` INT NOT NULL DEFAULT 0, `ccname` VARCHAR(128) COLLATE 'utf8mb4_unicode_ci', `message` INT NOT NULL DEFAULT 0, `ccmessage` VARCHAR(16) COLLATE 'utf8mb4_unicode_ci', `ccaccess` INT NOT NULL DEFAULT 0, PRIMARY KEY (`auth`), CONSTRAINT `%sch_auth` FOREIGN KEY (`auth`) REFERENCES `%susers` (`auth`) ON UPDATE CASCADE ON DELETE CASCADE) ENGINE=INNODB;",
			gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);
	}

	else
	{
		FormatEx(sQuery, 512,
			"CREATE TABLE IF NOT EXISTS `%schat` (`auth` INT NOT NULL, `name` INT NOT NULL DEFAULT 0, `ccname` VARCHAR(128), `message` INT NOT NULL DEFAULT 0, `ccmessage` VARCHAR(16), `ccaccess` INT NOT NULL DEFAULT 0, PRIMARY KEY (`auth`), CONSTRAINT `%sch_auth` FOREIGN KEY (`auth`) REFERENCES `%susers` (`auth`) ON UPDATE CASCADE ON DELETE CASCADE);",
			gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);
	}
	
	gH_SQL.Query(SQL_CreateTable_Callback, sQuery);
}

public void SQL_CreateTable_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer error! Chat table creation failed. Reason: %s", error);

		return;
	}

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && gCV_CustomChat.IntValue > 0)
		{
			LoadFromDatabase(i);
		}
	}
}

void SaveToDatabase(int client)
{
	if(!gB_ChangedSinceLogin[client])
	{
		return;
	}

	int iSteamID = GetSteamAccountID(client);

	if(iSteamID == 0)
	{
		return;
	}

	int iLength = ((strlen(gS_CustomName[client]) * 2) + 1);
	char[] sEscapedName = new char[iLength];
	gH_SQL.Escape(gS_CustomName[client], sEscapedName, iLength);

	iLength = ((strlen(gS_CustomMessage[client]) * 2) + 1);
	char[] sEscapedMessage = new char[iLength];
	gH_SQL.Escape(gS_CustomMessage[client], sEscapedMessage, iLength);

	char sQuery[512];
	FormatEx(sQuery, 512,
		"REPLACE INTO %schat (auth, name, ccname, message, ccmessage) VALUES (%d, %d, '%s', %d, '%s');",
		gS_MySQLPrefix, iSteamID, gB_NameEnabled[client], sEscapedName, gB_MessageEnabled[client], sEscapedMessage);

	gH_SQL.Query(SQL_UpdateUser_Callback, sQuery, 0, DBPrio_Low);
}

public void SQL_UpdateUser_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer error! Failed to insert chat data. Reason: %s", error);

		return;
	}
}

void LoadFromDatabase(int client)
{
	if(IsFakeClient(client))
	{
		return;
	}

	int iSteamID = GetSteamAccountID(client);

	if(iSteamID == 0)
	{
		return;
	}

	char sQuery[256];
	FormatEx(sQuery, 256, "SELECT name, ccname, message, ccmessage, ccaccess FROM %schat WHERE auth = %d;", gS_MySQLPrefix, iSteamID);

	gH_SQL.Query(SQL_GetChat_Callback, sQuery, GetClientSerial(client), DBPrio_Low);
}

public void SQL_GetChat_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (Chat cache update) SQL query failed. Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	gB_ChangedSinceLogin[client] = false;

	while(results.FetchRow())
	{
		gB_CCAccess[client] = view_as<bool>(results.FetchInt(4));

		if (!gB_CCAccess[client])
		{
			return;
		}

		gB_NameEnabled[client] = view_as<bool>(results.FetchInt(0));
		results.FetchString(1, gS_CustomName[client], 128);

		gB_MessageEnabled[client] = view_as<bool>(results.FetchInt(2));
		results.FetchString(3, gS_CustomMessage[client], 16);
	}
}

void RemoveFromString(char[] buf, char[] thing, int extra)
{
	int index;
	extra += strlen(thing);
	while ((index = StrContains(buf, thing, true)) != -1)
	{
		while (buf[index] != 0)
		{
			buf[index] = buf[index+extra];
			++index;
		}
	}
}

public int Native_GetPlainChatrank(Handle handler, int numParams)
{
	char buf[MAXLENGTH_NAME];
	int client = GetNativeCell(1);
	bool includename = !(GetNativeCell(4) == 0);
	int iChatrank = gI_ChatSelection[client];

	if (HasCustomChat(client) && iChatrank == -1 && gB_NameEnabled[client])
	{
		strcopy(buf, sizeof(buf), gS_CustomName[client]);
	}
	else
	{
		if (iChatrank < 0)
		{
			for(int i = 0; i < gA_ChatRanks.Length; i++)
			{
				if(HasRankAccess(client, i))
				{
					iChatrank = i;

					break;
				}
			}
		}

		if (0 <= iChatrank <= (gA_ChatRanks.Length - 1))
		{
			chatranks_cache_t cache;
			gA_ChatRanks.GetArray(iChatrank, cache, sizeof(chatranks_cache_t));

			strcopy(buf, sizeof(buf), cache.sName);
		}
	}

	for (int i = 0; i < sizeof(gS_GlobalColorNames); i++)
	{
		ReplaceString(buf, sizeof(buf), gS_GlobalColorNames[i], "");
	}

	if (gEV_Type == Engine_CSGO)
	{
		for (int i = 0; i < sizeof(gS_CSGOColorNames); i++)
		{
			ReplaceString(buf, sizeof(buf), gS_CSGOColorNames[i], "");
		}
	}

	RemoveFromString(buf, "^", 6);
	RemoveFromString(buf, "{RGB}", 6);
	RemoveFromString(buf, "&", 8);
	RemoveFromString(buf, "{RGBA}", 8);

	char sName[MAX_NAME_LENGTH];
	if (includename /* || iChatRank == -1*/)
	{
		GetClientName(client, sName, MAX_NAME_LENGTH);
	}

	ReplaceString(buf, sizeof(buf), "{name}", sName);
	ReplaceString(buf, sizeof(buf), "{rand}", "");

	if (gEV_Type != Engine_TF2)
	{
		char sTag[32];
		CS_GetClientClanTag(client, sTag, 32);
		ReplaceString(buf, sizeof(buf), "{clan}", sTag);
	}

	if (gB_Rankings)
	{
		int iRank = Shavit_GetRank(client);
		char sRank[16];
		IntToString(iRank, sRank, 16);
		ReplaceString(buf, sizeof(buf), "{rank}", sRank);

		int iRanked = Shavit_GetRankedPlayers();

		if (iRanked == 0)
		{
			iRanked = 1;
		}

		float fPercentile = (float(iRank) / iRanked) * 100.0;
		FormatEx(sRank, 16, "%.01f", fPercentile);
		ReplaceString(buf, sizeof(buf), "{rank1}", sRank);

		FormatEx(sRank, 16, "%.02f", fPercentile);
		ReplaceString(buf, sizeof(buf), "{rank2}", sRank);
	
		FormatEx(sRank, 16, "%.03f", fPercentile);
		ReplaceString(buf, sizeof(buf), "{rank3}", sRank);
	}

	TrimString(buf);
	SetNativeString(2, buf, GetNativeCell(3), true);
	return 0;
}
