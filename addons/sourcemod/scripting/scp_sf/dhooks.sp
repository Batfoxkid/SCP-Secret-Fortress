enum ThinkFunctionEnum
{
	ThinkFunction_None,
	ThinkFunction_SentryThink,
	ThinkFunction_RegenThink
}

static DynamicDetour AllowedToHealTarget;
static DynamicHook SetWinningTeam;
static DynamicHook RoundRespawn;
static DynamicHook ForceRespawn;
static int ForceRespawnHook[MAXTF2PLAYERS];
static int ThinkData[MAXENTITIES];
static ThinkFunctionEnum ThinkFunction;
static int CalculateSpeedClient;
//static int ClientTeam;

void DHook_Setup(GameData gamedata)
{
	DHook_CreateDetour(gamedata, "CBaseEntity::InSameTeam", DHook_InSameTeamPre);
	DHook_CreateDetour(gamedata, "CBaseEntity::PhysicsDispatchThink", DHook_PhysicsDispatchThinkPre, DHook_PhysicsDispatchThinkPost);
	//DHook_CreateDetour(gamedata, "CLagCompensationManager::StartLagCompensation", DHook_StartLagCompensationPre, DHook_StartLagCompensationPost);
	DHook_CreateDetour(gamedata, "CTFGameMovement::ProcessMovement", DHook_ProcessMovementPre);
	DHook_CreateDetour(gamedata, "CTFPlayer::CanPickupDroppedWeapon", DHook_CanPickupDroppedWeaponPre);
	DHook_CreateDetour(gamedata, "CTFPlayer::DoAnimationEvent", DHook_DoAnimationEventPre, _);
	DHook_CreateDetour(gamedata, "CTFPlayer::DropAmmoPack", DHook_DropAmmoPackPre);
	DHook_CreateDetour(gamedata, "CTFPlayer::Taunt", DHook_TauntPre, DHook_TauntPost);
	DHook_CreateDetour(gamedata, "CTFPlayer::TeamFortress_CalculateMaxSpeed", DHook_CalculateMaxSpeedPre, DHook_CalculateMaxSpeedPost);

	// TODO: DHook_CreateDetour version of this
	AllowedToHealTarget = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Bool, ThisPointer_CBaseEntity);
	if(AllowedToHealTarget)
	{
		if(AllowedToHealTarget.SetFromConf(gamedata, SDKConf_Signature, "CWeaponMedigun::AllowedToHealTarget"))
		{
			AllowedToHealTarget.AddParam(HookParamType_CBaseEntity);
			if(!AllowedToHealTarget.Enable(Hook_Pre, DHook_AllowedToHealTarget))
				LogError("[Gamedata] Failed to detour CWeaponMedigun::AllowedToHealTarget");
		}
		else
		{
			LogError("[Gamedata] Could not find CWeaponMedigun::AllowedToHealTarget");
		}
	}
	else
	{
		LogError("[Gamedata] Could not find CWeaponMedigun::AllowedToHealTarget");
	}

	SetWinningTeam = DynamicHook.FromConf(gamedata, "CTeamplayRules::SetWinningTeam");
	if(!SetWinningTeam)
		LogError("[Gamedata] Could not find CTeamplayRules::SetWinningTeam");

	RoundRespawn = DynamicHook.FromConf(gamedata, "CTeamplayRoundBasedRules::RoundRespawn");
	if(!RoundRespawn)
		LogError("[Gamedata] Could not find CTFPlayer::RoundRespawn");

	ForceRespawn = DynamicHook.FromConf(gamedata, "CBasePlayer::ForceRespawn");
	if(!ForceRespawn)
		LogError("[Gamedata] Could not find CBasePlayer::ForceRespawn");
}

static void DHook_CreateDetour(GameData gamedata, const char[] name, DHookCallback preCallback = INVALID_FUNCTION, DHookCallback postCallback = INVALID_FUNCTION)
{
	DynamicDetour detour = DynamicDetour.FromConf(gamedata, name);
	if(detour)
	{
		if(preCallback!=INVALID_FUNCTION && !DHookEnableDetour(detour, false, preCallback))
			LogError("[Gamedata] Failed to enable pre detour: %s", name);
		
		if(postCallback!=INVALID_FUNCTION && !DHookEnableDetour(detour, true, postCallback))
			LogError("[Gamedata] Failed to enable post detour: %s", name);

		delete detour;
	}
	else
	{
		LogError("[Gamedata] Could not find %s", name);
	}
}

void DHook_HookClient(int client)
{
	if(ForceRespawn)
		ForceRespawnHook[client] = ForceRespawn.HookEntity(Hook_Pre, client, DHook_ForceRespawn);
}

void DHook_UnhookClient(int client)
{
	DynamicHook.RemoveHook(ForceRespawnHook[client]);
}

void DHook_MapStart()
{
	if(SetWinningTeam)
		SetWinningTeam.HookGamerules(Hook_Pre, DHook_SetWinningTeam);

	if(RoundRespawn)
		RoundRespawn.HookGamerules(Hook_Pre, DHook_RoundRespawn);
}

public MRESReturn DHook_RoundRespawn()
{
	if(Enabled || !Ready)
		return;

	DClassEscaped = 0;
	DClassCaptured = 0;
	DClassMax = 1;
	SciEscaped = 0;
	SciCaptured = 0;
	SciMax = 0;
	SCPKilled = 0;
	SCPMax = 0;

	int total;
	int[] clients = new int[MaxClients];
	for(int client=1; client<=MaxClients; client++)
	{
		Client[client].NextSongAt = 0.0;
		Client[client].AloneIn = FAR_FUTURE;
		if(!IsValidClient(client) || GetClientTeam(client)<=view_as<int>(TFTeam_Spectator))
		{
			Client[client].Class = Class_Spec;
			continue;
		}

		if(TestForceClass[client] <= Class_Spec)
		{
			clients[total++] = client;
			continue;
		}

		Client[client].Class = TestForceClass[client];
		TestForceClass[client] = Class_Spec;
		switch(Client[client].Class)
		{
			case Class_DBoi:
			{
				DClassMax++;
			}
			case Class_Scientist:
			{
				SciMax++;
			}
			default:
			{
				if(IsSCP(client))
					SCPMax++;
			}
		}
		AssignTeam(client);
	}

	if(!total)
		return;

	Enabled = true;

	int client = clients[GetRandomInt(0, total-1)];
	switch(Gamemode)
	{
		case Gamemode_Nut:
			Client[client].Class = total>1 ? Class_173 : Class_DBoi;

		case Gamemode_Steals:
			Client[client].Class = total>1 ? Class_Stealer : Class_DBoi;

		default:
			Client[client].Class = Class_DBoi;
	}
	AssignTeam(client);

	float time = GetEngineTime()+5.0;
	ArrayList list = GetSCPList();
	for(int i; i<total; i++)
	{
		if(clients[i] == client)
			continue;

		if(Client[clients[i]].Setup(view_as<TFTeam>(GetRandomInt(2, 3)), IsFakeClient(clients[i]), list, DClassMax, SciMax, SCPMax) != Class_DBoi)
			Client[clients[i]].InvisFor = time;

		AssignTeam(clients[i]);
	}
	delete list;
}

public MRESReturn DHook_AllowedToHealTarget(int weapon, DHookReturn ret, DHookParam param)
{
	if(weapon==-1 || param.IsNull(1))
		return MRES_Ignored;

	//int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	int target = param.Get(1);
	if(!IsValidClient(target) || !IsPlayerAlive(target))
		return MRES_Ignored;

	ret.Value = false;
	return MRES_ChangedOverride;
}

public MRESReturn DHook_ForceRespawn(int client)
{
	if(Enabled && Client[client].Class==Class_Spec && !CvarSpecGhost.BoolValue)
		return MRES_Supercede;

	if(view_as<TFClassType>(GetEntProp(client, Prop_Send, "m_iDesiredPlayerClass")) == TFClass_Unknown)
		SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", ClassClass[Client[client].Class]);

	return MRES_Ignored;
}

public MRESReturn DHook_SetWinningTeam(DHookParam param)
{
	if(Enabled)
		return MRES_Supercede;

	param.Set(4, false);
	return MRES_ChangedOverride;
}

/*public MRESReturn DHook_StartLagCompensationPre(Address manager, DHookParam param)
{
	int client = param.Get(1);
	ClientTeam = GetClientTeam(client);
	ChangeClientTeamEx(client, TFTeam_Red);
}

public MRESReturn DHook_StartLagCompensationPost(Address manager, DHookParam param)
{
	int client = param.Get(1);
	ChangeClientTeamEx(client, ClientTeam);
}*/

public MRESReturn DHook_PhysicsDispatchThinkPre(int entity)
{
	//This detour calls everytime an entity was about to call a think function, useful as it only requires 1 gamedata
	if(Enabled)
	{
		static char classname[256];
		if(GetEntityClassname(entity, classname, sizeof(classname)))
		{
			if(StrEqual(classname, "obj_sentrygun"))	// CObjectSentrygun::SentryThink
			{
				ThinkFunction = ThinkFunction_SentryThink;

				//Sentry can only target one team, move all friendly to sentry team, move everyone else to enemy team.
				//CTeam class is used to collect players, so m_iTeamNum change wont be enough to fix it.
				TFTeam team = TF2_GetTeam(entity);
				Address address = SDKCall_GetGlobalTeam(team==TFTeam_Red ? TFTeam_Blue : TFTeam_Red);

				if(address != Address_Null)
				{
					for(int client=1; client<=MaxClients; client++)
					{
						if(!IsValidClient(client) || IsSpec(client))
							continue;

						if(IsSCP(client))
						{
							SDKCall_AddPlayer(address, client);
						}
						else
						{
							SDKCall_RemovePlayer(address, client);
						}
					}
				}

				int building = MaxClients+1;
				while((building=FindEntityByClassname(building, "obj_*")) > MaxClients)
				{
					ThinkData[building] = GetEntProp(building, Prop_Send, "m_iTeamNum");
					if(!GetEntProp(building, Prop_Send, "m_bPlacing"))
						SDKCall_ChangeTeam(building, team);
				}

				//eyeball_boss uses InSameTeam check but obj_sentrygun owner is itself
				SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", GetEntPropEnt(entity, Prop_Send, "m_hBuilder"));
				return MRES_Ignored;
			}

			if(StrEqual(classname, "player"))
			{
				if(IsPlayerAlive(entity) && SDKCall_GetNextThink(entity, "RegenThink")==-1.0)	// CTFPlayer::RegenThink
				{
					if(Client[entity].Class == Class_096)
					{
						ThinkFunction = ThinkFunction_RegenThink;
						TF2_SetPlayerClass(entity, TFClass_Medic);
						return MRES_Ignored;
					}
					else if(TF2_GetPlayerClass(entity) == TFClass_Medic)
					{
						ThinkFunction = ThinkFunction_RegenThink;
						TF2_SetPlayerClass(entity, TFClass_Unknown);
						return MRES_Ignored;
					}
				}
			}
		}
	}
	ThinkFunction = ThinkFunction_None;
	return MRES_Ignored;
}

public MRESReturn DHook_PhysicsDispatchThinkPost(int entity)
{
	switch(ThinkFunction)
	{
		case ThinkFunction_SentryThink:
		{
			TFTeam team = TF2_GetTeam(entity)==TFTeam_Red ? TFTeam_Blue : TFTeam_Red;
			Address address = SDKCall_GetGlobalTeam(team);

			for(int client=1; client<=MaxClients; client++)
			{
				if(!IsValidClient(client) || IsSpec(client))
					continue;

				if(IsSCP(client))
				{
					SDKCall_RemovePlayer(address, client);
				}
				else if(Client[client].TeamTF() == team)
				{
					SDKCall_AddPlayer(address, client);
				}
			}

			int building = MaxClients+1;
			while((building=FindEntityByClassname(building, "obj_*")) > MaxClients)
			{
				if(!GetEntProp(building, Prop_Send, "m_bPlacing"))
					SDKCall_ChangeTeam(building, ThinkData[building]);
			}

			SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", entity);
		}
		case ThinkFunction_RegenThink:
		{
			if(Client[entity].Class == Class_096)
			{
				TF2_SetPlayerClass(entity, view_as<TFClassType>(ClassClass[Class_096]));
			}
			else if(TF2_GetPlayerClass(entity) == TFClass_Unknown)
			{
				TF2_SetPlayerClass(entity, TFClass_Medic);
			}
		}
	}

	ThinkFunction = ThinkFunction_None;
	return MRES_Ignored;
}

public MRESReturn DHook_CanPickupDroppedWeaponPre(int client, DHookReturn ret, DHookParam param)
{
	if(!IsSpec(client) && !IsSCP(client) && !Client[client].Disarmer)
		PickupWeapon(client, param.Get(1));

	ret.Value = false;
	return MRES_Supercede;
}

public MRESReturn DHook_DoAnimationEventPre(int client, DHookParam param)
{
	if(Client[client].OnAnimation != INVALID_FUNCTION)
	{
		PlayerAnimEvent_t anim = param.Get(1);
		int data = param.Get(2);

		Call_StartFunction(null, Client[client].OnAnimation);
		Call_PushCell(client);
		Call_PushCellRef(anim);
		Call_PushCellRef(data);

		Action action;
		Call_Finish(action);

		if(action >= Plugin_Handled)
			return MRES_Supercede;

		if(action == Plugin_Changed)
		{
			param.Set(1, anim);
			param.Set(2, data);
			return MRES_ChangedOverride;
		}
	}
	return MRES_Ignored;
}

public MRESReturn DHook_DropAmmoPackPre(int client, DHookParam param)
{
	//Ignore feign death
	if(!param.Get(2) && !IsSpec(client))
		Items_DropAllItems(client);

	//Prevent TF2 dropping anything else
	return MRES_Supercede;
}

public MRESReturn DHook_InSameTeamPre(int entity, DHookReturn ret, DHookParam param)
{
	bool result;
	if(!param.IsNull(1))
	{
		int ent1 = GetOwnerLoop(entity);
		int ent2 = GetOwnerLoop(param.Get(1));
		if(ent1 == ent2)
		{
			result = true;
		}
		else if(IsValidClient(ent1) && IsValidClient(ent2))
		{
			result = IsFriendly(Client[ent1].Class, Client[ent2].Class);
		}
	}

	ret.Value = result;
	return MRES_Supercede;
}

public MRESReturn DHook_ProcessMovementPre(DHookParam param)
{
	if(!Enabled)
		return MRES_Ignored;

	param.SetObjectVar(2, 60, ObjectValueType_Float, CvarSpeedMax.FloatValue);
	return MRES_ChangedHandled;
}

public MRESReturn DHook_CalculateMaxSpeedPre(Address address, DHookReturn ret)
{
	CalculateSpeedClient = SDKCall_GetBaseEntity(address);
}

public MRESReturn DHook_CalculateMaxSpeedPost(int clientwhen, DHookReturn ret)
{
	int client = CalculateSpeedClient;
	if(!IsClientInGame(client) || !IsPlayerAlive(client))
		return MRES_Ignored;

	float speed = 300.0;
	if(Client[client].InvisFor != FAR_FUTURE)
	{
		if(TF2_IsPlayerInCondition(client, TFCond_Dazed))
			return MRES_Ignored;

		switch(Client[client].Class)
		{
			case Class_Spec:
			{
				speed = 400.0;
			}
			case Class_DBoi, Class_Scientist:
			{
				if(Gamemode == Gamemode_Steals)
				{
					speed = Client[client].Sprinting ? 360.0 : 270.0;
				}
				else
				{
					speed = Client[client].Disarmer ? 230.0 : Client[client].Sprinting ? 310.0 : 260.0;
				}
			}
			case Class_Chaos, Class_MTFE:
			{
				speed = (Client[client].Sprinting && !Client[client].Disarmer) ? 270.0 : 230.0;
			}
			case Class_MTF3:
			{
				speed = Client[client].Disarmer ? 230.0 : Client[client].Sprinting ? 280.0 : 240.0;
			}
			case Class_Guard, Class_MTF, Class_MTF2, Class_MTFS:
			{
				speed = Client[client].Disarmer ? 230.0 : Client[client].Sprinting ? 290.0 : 250.0;
			}
			default:
			{
				Function_OnSpeed(client, speed);
			}
		}

		speed *= CvarSpeedMulti.FloatValue;
	}

	ret.Value = speed;
	return MRES_Override;
}

public MRESReturn DHook_TauntPre(int client)
{
	//Dont allow taunting if disguised or cloaked
	if(TF2_IsPlayerInCondition(client, TFCond_Disguising) || TF2_IsPlayerInCondition(client, TFCond_Disguised) || TF2_IsPlayerInCondition(client, TFCond_Cloaked))
		return MRES_Supercede;

	if(Client[client].Class!=Class_Scientist && Client[client].Class!=Class_Guard)
	{
		//Player wants to taunt, set class to whoever can actually taunt with active weapon
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if(weapon > MaxClients)
		{
			TFClassType class = TF2_GetDefaultClassFromItem(weapon);
			if(class != TFClass_Unknown)
				TF2_SetPlayerClass(client, class, false);
		}
	}
	return MRES_Ignored;
}

public MRESReturn DHook_TauntPost(int client)
{
	TF2_SetPlayerClass(client, ClassClass[Client[client].Class], false);
}

public MRESReturn DHook_GetMaxAmmoPre(int client, DHookReturn ret, DHookParam param)
{
	switch(param.Get(1))
	{
		case Ammo_Micro:
		{
			ret.Value = 1000;
		}
		case Ammo_9mm:
		{
			if(Client[client].Class == Class_Chaos)
			{
				ret.Value = 100;
			}
			else if(Client[client].Class < Class_Guard)
			{
				ret.Value = 50;
			}
			else
			{
				ret.Value = 200;
			}
		}
		case Ammo_Metal:
		{
			ret.Value = 400;
		}
		case Ammo_7mm:
		{
			if(Client[client].Class == Class_Chaos)
			{
				ret.Value = 200;
			}
			else if(Client[client].Class < Class_Guard)
			{
				ret.Value = 70;
			}
			else
			{
				ret.Value = 100;
			}
		}
		case Ammo_5mm:
		{
			if(Client[client].Class < Class_Guard)
			{
				ret.Value = 80;
			}
			else
			{
				ret.Value = 160;
			}
		}
		case Ammo_Grenade:
		{
			ret.Value = 3;
		}
		default:
		{
			return MRES_Ignored;
		}
	}
	return MRES_Supercede;
}