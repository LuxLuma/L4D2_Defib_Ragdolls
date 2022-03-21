#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#include <lux_library>

#define REQUIRE_PLUGIN
#include <LMCL4D2CDeathHandler>
#include <LMCCore>


#pragma newdecls required

#define PLUGIN_VERSION "1.2.7"

#define RAGDOLL_OFFSET_TOLERANCE 25.0

static int iDeathModelRef[2048+1];
static int iRagdollRef[2048+1];
static float fRagdollVelocity[2048+1][3];
static int iRagdollPushesLeft[2048+1];
static float fClientVelocity[MAXPLAYERS+1][3];
static bool bIncap[MAXPLAYERS+1];

static int iTrackedRagdollRef[MAXPLAYERS+1];

static bool bSpawnedGlowModels = false;
static bool bShowGlow[MAXPLAYERS+1];
static int iGlowModelRef[2048+1];

static Handle hCvar_Human_VPhysics_Mode;
static int iHuman_VPhysics_Mode = true;

static bool bOverrideBoogie = false;
static int iZapIndex;
static int bIgnoreZap = false;

//survivor models seem to have 5x the mass of a common infected physics bug if pushed too often per tick and have high force, higher tickrates have better results
static const char sFatModels[10][] =
{
	"models/survivors/survivor_gambler.mdl",
	"models/survivors/survivor_producer.mdl",
	"models/survivors/survivor_coach.mdl",
	"models/survivors/survivor_mechanic.mdl",
	"models/survivors/survivor_namvet.mdl",
	"models/survivors/survivor_teenangst.mdl",
	"models/survivors/survivor_teenangst_light.mdl",
	"models/survivors/survivor_biker.mdl",
	"models/survivors/survivor_biker_light.mdl",
	"models/survivors/survivor_manager.mdl"
};

static const char sBugModels[2][] =
{
	"models/npcs/rescue_pilot_01.mdl",
	"models/infected/common_female01.mdl"
};

static const char sPlaceHolder[] = "models/infected/common_male01.mdl";


#define MAXBLOOD_RANGE 140.0
#define DECAL_AMOUNT_WITCH 40
#define DECALS_SEND_PERTICK 8

char g_rngSpray[][] =
{
	"decals/blood1_subrect",
	"decals/blood2_subrect",
	"decals/blood3_subrect",
	"decals/blood4_subrect",
	"decals/blood5_subrect",
	"decals/blood6_subrect",
};

int g_iDecals[sizeof(g_rngSpray)];
int g_DecalArraySize = sizeof(g_rngSpray);


ArrayList g_BloodQueue;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if(GetEngineVersion() != Engine_Left4Dead2 )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public Plugin myinfo =
{
	name = "[L4D2]Defib_Ragdolls",
	author = "Lux",
	description = "Makes survivor static deathmodel simulate a ragdoll",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?p=2633939"
};

public void OnPluginStart()
{
	CreateConVar("defib_Ragdolls_version", PLUGIN_VERSION, "", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	hCvar_Human_VPhysics_Mode = CreateConVar("dr_survivor_ragdoll_mode", "1", "2 = [User common infected as vphysics for consistency] 1 = [Only use common infected vphysics for bugged models and survivor model(they heavy)] 0 = [Use model vphysics when available except for bugged models]", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	HookConVarChange(hCvar_Human_VPhysics_Mode, eCvarChanged);
	
	AutoExecConfig(true, "Defib_ragdolls");
	CvarChanged();
	
	CreateTimer(0.1, GlowThink, _, TIMER_REPEAT);
	
	AddTempEntHook("EffectDispatch", TE_Zap);
	
	HookUserMessage(GetUserMessageId("WitchBloodSplatter"), WitchBloodSplatter, true);
	
	--g_DecalArraySize;
	g_BloodQueue = new ArrayList(3);
}

public void OnMapStart()
{
	PrecacheModel(sPlaceHolder, true);
	iZapIndex = Precache_Particle_System("item_defibrillator_body");
	Precache_Boogie();
	
	for(int i; i < sizeof(g_rngSpray); ++i)
		g_iDecals[i] = PrecacheDecal(g_rngSpray[i]);
		
	g_BloodQueue.Clear();
}

public void eCvarChanged(Handle convar, const char[] oldValue, const char[] newValue)
{
	CvarChanged();
}

void CvarChanged()
{
	iHuman_VPhysics_Mode = GetConVarInt(hCvar_Human_VPhysics_Mode);
}

public void LMC_OnClientDeathModelCreated(int iClient, int iDeathModel, int iOverlayModel)
{
	int iEntity = CreateEntityByName("physics_prop_ragdoll");
	if(iEntity < 1)
		return;
	
	char sModel[PLATFORM_MAX_PATH];
	
	if(iOverlayModel > -1)
	{
		GetEntPropString(iOverlayModel, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
		AcceptEntityInput(iOverlayModel, "Kill");
	}
	else
		GetEntPropString(iClient, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
	
	if(sModel[0] == '\0')
	{
		AcceptEntityInput(iEntity, "Kill");
		return;
	}
	
	switch(iHuman_VPhysics_Mode)
	{
		case 0:
		{
			if(IsBugModel(sModel))
				DispatchKeyValue(iEntity, "model", sPlaceHolder);
			else
				DispatchKeyValue(iEntity, "model", sModel);
		}
		case 1:
		{
			if(IsBugModel(sModel) || IsFat(sModel))
				DispatchKeyValue(iEntity, "model", sPlaceHolder);
			else
				DispatchKeyValue(iEntity, "model", sModel);
		}
		case 2:
		{
			DispatchKeyValue(iEntity, "model", sPlaceHolder);
		}
		default:
		{
			DispatchKeyValue(iEntity, "model", sPlaceHolder);
		}
	}
		
	LMC_SetEntityOverlayModel(iEntity, sModel);
	
	DispatchKeyValue(iEntity, "spawnflags", "4");
	
	float fVec[3];
	GetEntPropVector(iDeathModel, Prop_Send, "m_vecOrigin", fVec);
	if(!bIncap[iClient])
		fVec[2] += 10.0;// so legs dont get stuck in the floor
	
	TeleportEntity(iEntity, fVec, NULL_VECTOR, NULL_VECTOR);
	TeleportEntity(iDeathModel, fVec, NULL_VECTOR, NULL_VECTOR);
	
	DispatchSpawn(iEntity);
	ActivateEntity(iEntity);
	
	GetEntPropVector(iDeathModel, Prop_Data, "m_angAbsRotation", fVec);
	FixAngles(sModel, fVec[0], bIncap[iClient]);
	TeleportEntity(iEntity, NULL_VECTOR, fVec, NULL_VECTOR);
	
	SetEdictFlags(iDeathModel, FL_EDICT_DONTSEND);
	
	iDeathModelRef[iDeathModel] = EntIndexToEntRef(iEntity);
	iRagdollRef[iEntity] = EntIndexToEntRef(iDeathModel);
	
	if(bSpawnedGlowModels)
		SetUpGlowModel(iEntity);
	
	CreateTimer(1.0, CheckDist, iRagdollRef[iEntity], TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);// for plugins or maps that like to teleport deathmodels around parenting wont work for this (e.g tank_challenge)
	SDKHook(iEntity, SDKHook_VPhysicsUpdatePost, RagdollPhysicsUpdatePost);
	SDKHook(iEntity, SDKHook_VPhysicsUpdate, VPhysicsPush);
	SDKHook(iEntity, SDKHook_OnTakeDamage, ApplyRagdollForce);
	
	int iTickRate = RoundFloat(1 / GetTickInterval());
	fRagdollVelocity[iEntity][0] = fClientVelocity[iClient][0] / (iTickRate / 30); 
	fRagdollVelocity[iEntity][1] = fClientVelocity[iClient][1] / (iTickRate / 30); 
	fRagdollVelocity[iEntity][2] = fClientVelocity[iClient][2] / (iTickRate / 30);
	
	iRagdollPushesLeft[iEntity] = iTickRate;
	
	DataPack hDataPack = CreateDataPack();
	hDataPack.WriteCell(GetClientUserId(iClient));
	hDataPack.WriteCell(EntIndexToEntRef(iEntity));
	
	RequestFrame(AttachClient, hDataPack);
	//SetEntPropEnt(iClient, Prop_Send, "m_hRagdoll", iEntity);
	SetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity", iClient);//other plugins
	SetEntProp(iEntity, Prop_Send, "m_nForceBone", GetEntProp(iClient, Prop_Send, "m_nForceBone"));// no idea what this does valve does it
	
	SetEntProp(iClient, Prop_Data, "m_bForcedObserverMode", 1);//i set this for me to keep track if game does something
	SetEntPropEnt(iClient, Prop_Send, "m_hObserverTarget", iEntity);
	SetEntProp(iClient, Prop_Send, "m_iObserverMode", 1);
	
	iTrackedRagdollRef[iClient] = EntIndexToEntRef(iEntity);
	SDKHook(iClient, SDKHook_PostThinkPost, FollowCam);
}

public void FollowCam(int iClient)
{
	if(!GetEntProp(iClient, Prop_Data, "m_bForcedObserverMode") || 
		GetEntProp(iClient, Prop_Send, "m_iObserverMode") != 1 ||
		IsPlayerAlive(iClient) || GetClientTeam(iClient) != 2)
	{
		SDKUnhook(iClient, SDKHook_PostThinkPost, FollowCam);
		return;
	}
	
	int iRagdoll = GetEntPropEnt(iClient, Prop_Send, "m_hObserverTarget");
	if(iRagdoll == INVALID_ENT_REFERENCE || iRagdoll != EntRefToEntIndex(iTrackedRagdollRef[iClient]))
	{
		SDKUnhook(iClient, SDKHook_PostThinkPost, FollowCam);
		return;
	}
	
	float vecClientPos[3];
	float vecRagdollPos[3];
	float vecResult[3];
	
	GetAbsOrigin(iClient, vecClientPos);
	GetAbsOrigin(iRagdoll, vecRagdollPos);
	
	VectorLerp(vecClientPos, vecRagdollPos, 0.05, vecResult);
	
	if(GetVectorDistance(vecClientPos, vecResult) > 1.0)
	{
		TeleportEntity(iClient, vecResult, NULL_VECTOR, NULL_VECTOR);
	}
}

public void AttachClient(DataPack hDataPack)
{
	hDataPack.Reset();
	int iClient = GetClientOfUserId(hDataPack.ReadCell());
	int iRagdoll = EntRefToEntIndex(hDataPack.ReadCell());
	delete hDataPack;
	
	if(iClient < 1 || !IsClientInGame(iClient) || IsPlayerAlive(iClient))//forgot the alive check :P
		return;
	
	if(!IsValidEntRef(iRagdoll))
		return;
		
	float vecRagdollPos[3];
	GetAbsOrigin(iRagdoll, vecRagdollPos);
	TeleportEntity(iClient, vecRagdollPos, NULL_VECTOR, NULL_VECTOR);
}

public void VPhysicsPush(int iEntity)
{
	if(iRagdollPushesLeft[iEntity] < 1)
	{
		SDKUnhook(iEntity, SDKHook_OnTakeDamage, ApplyRagdollForce);
		SDKUnhook(iEntity, SDKHook_VPhysicsUpdate, VPhysicsPush);
		return;
	}
	
	--iRagdollPushesLeft[iEntity];
	TickleRagdoll(iEntity);
}

public Action ApplyRagdollForce(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
	damageForce[0] = fRagdollVelocity[victim][0];
	damageForce[1] = fRagdollVelocity[victim][1];
	damageForce[2] = fRagdollVelocity[victim][2];
	GetEntPropVector(victim, Prop_Send, "m_vecOrigin", damagePosition);
	AddVectors(fRagdollVelocity[victim], damagePosition, damagePosition);
	return Plugin_Changed;
}

public void RagdollPhysicsUpdatePost(int iEntity)
{
	if(!IsValidEntRef(iRagdollRef[iEntity]))
		return;
	
	CheckDeathModelTeleport(iEntity, iRagdollRef[iEntity]);
}

public Action CheckDist(Handle hTimer, int iEntRef)
{
	if(!IsValidEntRef(iEntRef))
		return Plugin_Stop;
	
	static int iEntity; 
	iEntity = EntRefToEntIndex(iEntRef); 
	if(!IsValidEntRef(iDeathModelRef[iEntity]))
		return Plugin_Stop;

	CheckDeathModelTeleport(iDeathModelRef[iEntity], iEntity);
	return Plugin_Continue;
}

void CheckDeathModelTeleport(int iRagdoll, int iDeathModel)
{
	static float fPos1[3];
	static float fPos2[3];
	GetEntPropVector(iRagdoll, Prop_Send, "m_vecOrigin", fPos1);
	GetEntPropVector(iDeathModel, Prop_Send, "m_vecOrigin", fPos2);
	
	if(GetVectorDistance(fPos1, fPos2) > RAGDOLL_OFFSET_TOLERANCE)
	{
		fPos2[2] += 35.0;
		TeleportEntity(iRagdoll, fPos2, NULL_VECTOR, NULL_VECTOR);
		TeleportEntity(iDeathModel, fPos2, NULL_VECTOR, NULL_VECTOR);
		TickleRagdoll(iRagdoll);//incase the ragdoll is sleeping triggers vphysics
	}
	else
		TeleportEntity(iDeathModel, fPos1, NULL_VECTOR, NULL_VECTOR);
}

public void OnEntityDestroyed(int iEntity)
{
	if(iEntity < 1 || iEntity > 2048)
		return;
	
	if(IsValidEntRef(iDeathModelRef[iEntity]))
	{
		AcceptEntityInput(iDeathModelRef[iEntity], "kill");
		iDeathModelRef[iEntity] = -1;
	}
	if(IsValidEntRef(iRagdollRef[iEntity]))
	{
		AcceptEntityInput(iRagdollRef[iEntity], "kill");
		iRagdollRef[iEntity] = -1;
	}
}

public void eOnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype, int weapon, const float damageForce[3], const float damagePosition[3])
{
	if(GetEntProp(victim, Prop_Send, "m_isIncapacitated", 1) && !GetEntProp(victim, Prop_Send, "m_isHangingFromLedge", 1))
		bIncap[victim] = true;
	else
		bIncap[victim] = false;
	
	if(damagetype & DMG_FALL)
	{
		GetEntPropVector(victim, Prop_Data, "m_vecAbsVelocity", fClientVelocity[victim]);
		return;
	}
		
	fClientVelocity[victim][0] = damageForce[0];
	fClientVelocity[victim][1] = damageForce[1];
	fClientVelocity[victim][2] = damageForce[2];
}


void FixAngles(const char[] sModel, float &fAng, bool IncapAngle)
{
	if(IncapAngle)
	{
		if(StrEqual(sModel, "models/infected/witch_bride.mdl", false))
			fAng = -180.0;
		else
			fAng = -90.0;
	}
	else if(StrEqual(sModel, "models/infected/witch_bride.mdl", false))
		fAng = -90.0;
}

static bool IsValidEntRef(int iEntRef)
{
	return (iEntRef != 0 && EntRefToEntIndex(iEntRef) != INVALID_ENT_REFERENCE);
}

//credit smlib as guide for pointhurt
static void TickleRagdoll(int iRagdoll)
{
	static int iHurtPointRef = INVALID_ENT_REFERENCE;
	if(!IsValidEntRef(iHurtPointRef)) 
	{
		iHurtPointRef = EntIndexToEntRef(CreateEntityByName("point_hurt"));
		if (iHurtPointRef == INVALID_ENT_REFERENCE) 
			return;
		
		DispatchSpawn(iHurtPointRef);
	}
	
	char sTarget[32];
	FormatEx(sTarget, sizeof(sTarget), "__TickleTarget%i", iRagdoll);
	DispatchKeyValue(iHurtPointRef, "DamageTarget", sTarget);
	DispatchKeyValue(iRagdoll, "targetname", sTarget);
	SetEntProp(iHurtPointRef, Prop_Data, "m_bitsDamageType", DMG_CLUB);
	AcceptEntityInput(iHurtPointRef, "TurnOn");
	AcceptEntityInput(iHurtPointRef, "Hurt");
	AcceptEntityInput(iHurtPointRef, "TurnOff");
}

void SetupShock(int iRagdoll)
{
	int iOverlay = LMC_GetEntityOverlayModel(iRagdoll);
	if(iOverlay != -1)
	{
		float vecPos[3];
		GetAbsOrigin(iRagdoll, vecPos);
		TE_SetupParticle_ControlPoints(iZapIndex, iOverlay, vecPos);
		TE_SendToAllInRange(vecPos, RangeType_Visibility);
	}
	
	/*
	StartRagdollBoogie
    Begins ragdoll boogie effect for 5 seconds.
    Bug.png Bug: This input is actually supposed to use a parameter for how long the ragdoll should boogie, but it uses the wrong field type in the data description.
    Code Fix: In CRagdollProp's data description, find DEFINE_INPUTFUNC( FIELD_VOID, "StartRagdollBoogie", InputStartRadgollBoogie ) and replace FIELD_VOID with FIELD_FLOAT.
    */
	bOverrideBoogie = true;
	AcceptEntityInput(iRagdoll, "StartRagdollBoogie");
	bOverrideBoogie = false;
}

bool IsBugModel(const char[] sModel)
{
	for(int i = 0; i < 2; i++)
		if(StrEqual(sModel, sBugModels[i], false))
			return true;
	return false;
}

bool IsFat(const char[] sModel)
{
	for(int i = 0; i < 10; i++)
		if(StrEqual(sModel, sFatModels[i], false))
			return true;
	return false;
}

public Action ShouldTransmitGlow(int iEntity, int iClient)
{
	if(bShowGlow[iClient])
		return Plugin_Continue;
	return Plugin_Handled;
}

public Action GlowThink(Handle hTimer, any Cake)
{
	static int i;
	static bool bHasDefib;
	bHasDefib = false;
	for(i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != 2)
			continue;
		
		static char sWeapon[32];
		GetClientWeapon(i, sWeapon, sizeof(sWeapon));
		if(sWeapon[7] == 'd' && StrEqual(sWeapon, "weapon_defibrillator", false))
		{
			bHasDefib = true;
			bShowGlow[i] = true;
			continue;
		}
	}

	if(bSpawnedGlowModels && !bHasDefib)
	{
		for(i = MaxClients; i <= 2048; i++)
			if(IsValidEntRef(iGlowModelRef[i]))
				AcceptEntityInput(iGlowModelRef[i], "Kill");
		bSpawnedGlowModels = false;
		
		for(i = 1; i <= MaxClients; i++)
			bShowGlow[i] = false;
	}
	else if(!bSpawnedGlowModels && bHasDefib)
	{
		for(i = MaxClients; i <= 2048; i++)
			if(IsValidEntRef(iDeathModelRef[i]))
				if(!SetUpGlowModel(EntRefToEntIndex(iDeathModelRef[i])))
					break;
				
		bSpawnedGlowModels = true;
	}
}


bool SetUpGlowModel(int iEntity)
{
	static int iEnt;
	iEnt = CreateEntityByName("prop_dynamic_ornament");
	if(iEnt < 0)
		return false;
	
	static char sModel[PLATFORM_MAX_PATH];
	static int iOverlayModel;
	iOverlayModel = LMC_GetEntityOverlayModel(iEntity);
	if(iOverlayModel > -1)
		GetEntPropString(iOverlayModel, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
	else
		GetEntPropString(iEntity, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
	
	DispatchKeyValue(iEnt, "model", sModel);
	
	DispatchSpawn(iEnt);
	ActivateEntity(iEnt);
	
	SetVariantString("!activator");
	AcceptEntityInput(iEnt, "SetParent", iEntity);
	
	SetVariantString("!activator");
	AcceptEntityInput(iEnt, "SetAttached", iEntity);
	AcceptEntityInput(iEnt, "TurnOn");
	
	iGlowModelRef[iEnt] = EntIndexToEntRef(iEnt);
	
	SetEntProp(iEnt, Prop_Send, "m_iGlowType", 3);
	SetEntProp(iEnt, Prop_Send, "m_glowColorOverride", 180);
	SetEntProp(iEnt, Prop_Send, "m_nGlowRange", 2147483646);
	SetEntityRenderMode(iEnt, RENDER_NONE);
	SDKHook(iEnt, SDKHook_SetTransmit, ShouldTransmitGlow);
	return true;
}

public void OnEntityCreated(int iEntity, const char[] sClassname)
{
	if(bOverrideBoogie && StrEqual(sClassname, "env_ragdoll_boogie"))
	{
		SDKHook(iEntity, SDKHook_SpawnPost, BoogieSpawnPost);
		return;
	}
	
	if(sClassname[0] != 's' || !StrEqual(sClassname, "survivor_bot"))
	 	return;
	 
	SDKHook(iEntity, SDKHook_OnTakeDamageAlivePost, eOnTakeDamagePost);
}

public void BoogieSpawnPost(int iEntity)
{
	SetEntPropFloat(iEntity, Prop_Data, "m_flBoogieLength", 0.4);
}

void Precache_Boogie()
{
	int iEnt = CreateEntityByName("env_ragdoll_boogie");
	if(iEnt == -1)
		return;
	DispatchSpawn(iEnt);
	RemoveEntity(iEnt);
}

public Action TE_Zap(const char[] te_name, const int[] Players, int numClients, float delay)
{
	if(bIgnoreZap)
		return Plugin_Continue;
	
	static int iEffectIndex = INVALID_STRING_INDEX;
	if(iEffectIndex < 0)
	{
		iEffectIndex = __FindStringIndex2(FindStringTable("EffectDispatch"), "ParticleEffect");
		if(iEffectIndex == INVALID_STRING_INDEX)
			SetFailState("Unable to find EffectDispatch/ParticleEffect indexes");
	}
	
	if(TE_ReadNum("m_iEffectName") != iEffectIndex)
		return Plugin_Continue;
	
	if(TE_ReadNum("m_nHitBox") != iZapIndex)
		return Plugin_Continue;
	
	int iDeathModel = TE_ReadNum("entindex");
	if(IsValidEntRef(iDeathModelRef[iDeathModel]))
	{
		bIgnoreZap = true;
		SetupShock(EntRefToEntIndex(iDeathModelRef[iDeathModel]));
		bIgnoreZap = false;
	}
	return Plugin_Continue;
}


public void OnClientPutInServer(int iClient)
{
	if(IsFakeClient(iClient))
		return;
	
	SDKHook(iClient, SDKHook_OnTakeDamageAlivePost, eOnTakeDamagePost);
}

public Action WitchBloodSplatter(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	float vecPos[3];
	msg.ReadVecCoord(vecPos);
	
	//PrintToChatAll("WitchHit_Detect, bytesleft[%i]", msg.BytesLeft);
	
	for(int i; i < DECAL_AMOUNT_WITCH; ++i)
	{
		g_BloodQueue.PushArray(vecPos);
	}
	
	return Plugin_Handled;
}

public void OnGameFrame()
{
	int len = g_BloodQueue.Length;
	if(len < 1)
		return;
	
	float vecPos[3];
	float vecAng[3];
	float vecPosEnd[3];
	int limit = DECALS_SEND_PERTICK;
	
	for(int i = len - 1; i > -1; --i)
	{
		if(--limit <= 0)
			return;
		
		g_BloodQueue.GetArray(i, vecPos);
		g_BloodQueue.Erase(i);
		
		__RNGAngles(vecAng);
		OriginMove(vecPos, vecAng, vecPosEnd, MAXBLOOD_RANGE);
		TR_TraceRayFilter(vecPos, vecPosEnd, CONTENTS_IGNORE_NODRAW_OPAQUE|CONTENTS_AUX|CONTENTS_SOLID|CONTENTS_EMPTY|CONTENTS_WINDOW, RayType_EndPoint, TraceFilter_Decal);// simple bbox tracing
		
		if(SetupBloodDecal_FromTrace())
		{
			TE_SendToAllInRange(vecPosEnd, RangeType_Visibility);
		}
	}
}

bool SetupBloodDecal_FromTrace(Handle hTR=INVALID_HANDLE)
{
	if(!TR_DidHit(hTR))
		return false;
	
	int iSurf = TR_GetSurfaceFlags(hTR);
	if((iSurf & SURF_NODECALS) || (iSurf & SURF_NODRAW) || (iSurf & SURF_SKY))
	{
		return false;
	}
	
	float vecStart[3];
	float vecEnd[3];
	int iTarget = TR_GetEntityIndex(hTR);
	int iHitbox = TR_GetHitBoxIndex(hTR);
	TR_GetStartPosition(hTR, vecStart);
	TR_GetEndPosition(vecEnd, hTR);
	
	if(iTarget == 0)
	{
		if(iHitbox)
		{
			TE_SetupEntityDecal(vecEnd, vecStart, iTarget, iHitbox, g_iDecals[GetRandomInt(0, g_DecalArraySize)]);
		}
		else
		{
			TE_SetupWorldDecal(vecEnd, g_iDecals[GetRandomInt(0, g_DecalArraySize)]);
		}
	}
	return true;
}


stock void __RNGAngles(float fRNGAngle[3])
{
	fRNGAngle[0] = GetRandomFloat(-360.0, 360.0);
	fRNGAngle[1] = GetRandomFloat(-360.0, 360.0);
	fRNGAngle[2] = GetRandomFloat(-360.0, 360.0);
}

public bool TraceFilter_Decal(int entity, int contentsmask, int ignore)
{
	if(entity == 0)
		return true;
	return false;
}

stock void OriginMove(float fStartOrigin[3], float fStartAngles[3], float EndOrigin[3],  float fDistance)
{
	float fDirection[3];
	GetAngleVectors(fStartAngles, fDirection, NULL_VECTOR, NULL_VECTOR);

	EndOrigin[0] = fStartOrigin[0] + fDirection[0] * fDistance;
	EndOrigin[1] = fStartOrigin[1] + fDirection[1] * fDistance;
	EndOrigin[2] = fStartOrigin[2] + fDirection[2] * fDistance;
}

//Thanks Deathreus
// Figure out a middle point between source and destination in the given time
stock void VectorLerp(const float vec[3], const float dest[3], float time, float res[3])
{
    res[0] = vec[0] + (dest[0] - vec[0]) * time;
    res[1] = vec[1] + (dest[1] - vec[1]) * time;
    res[2] = vec[2] + (dest[2] - vec[2]) * time;
}

//Credit smlib https://github.com/bcserv/smlib
/**
 * Rewrite of FindStringIndex, which failed to work correctly in previous tests.
 * Searches for the index of a given string in a stringtable. 
 *
 * @param tableidx		Stringtable index.
 * @param str			String to find.
 * @return			The string index or INVALID_STRING_INDEX on error.
 **/
static stock int __FindStringIndex2(int tableidx, const char[] str)
{
	static char buf[1024];

	int numStrings = GetStringTableNumStrings(tableidx);
	for (int i=0; i < numStrings; i++) {
		ReadStringTable(tableidx, i, buf, sizeof(buf));
		
		if (StrEqual(buf, str)) {
			return i;
		}
	}
	
	return INVALID_STRING_INDEX;
}