#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define REQUIRE_PLUGIN
#include <LMCL4D2CDeathHandler>
#include <LMCCore>

#pragma newdecls required

#define PLUGIN_VERSION "1.0"

#define RAGDOLL_OFFSET_TOLERANCE 25.0

static int iDeathModelRef[2048+1];
static int iRagdollRef[2048+1];
static float fRagdollVelocity[2048+1][3];
static int iRagdollPushesLeft[2048+1];
static float fClientVelocity[MAXPLAYERS+1][3];
static bool bIncap[MAXPLAYERS+1];

static bool bSpawnedGlowModels = false;
static bool bShowGlow[MAXPLAYERS+1];
static int iGlowModelRef[2048+1];

//survivor models seem to have 5x the mass of a common infected physics bug if pushed too often per tick and have high force, higher tickrates have better results
static const char sFatOrBugModels[12][] =
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
	"models/survivors/survivor_manager.mdl",
	"models/npcs/rescue_pilot_01.mdl",
	"models/infected/common_female01.mdl"
};

static const char sPlaceHolder[] = "models/infected/common_male01.mdl";


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
	CreateTimer(0.1, GlowThink, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	PrecacheModel(sPlaceHolder, true);
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
	
	if(IsFatOrBugModel(sModel))
	{
		int iOverlay = LMC_SetEntityOverlayModel(iEntity, sModel);
		if(iOverlay < 1)
		{
			AcceptEntityInput(iEntity, "Kill");
			return;
		}
		DispatchKeyValue(iEntity, "model", sPlaceHolder);
		SetEntProp(iEntity, Prop_Send, "m_nMinGPULevel", 1);
		SetEntProp(iEntity, Prop_Send, "m_nMaxGPULevel", 1);
		SetEntityRenderMode(iEntity, RENDER_NONE);
	}
	else
		DispatchKeyValue(iEntity, "model", sModel);
	
	
	DispatchKeyValue(iEntity, "spawnflags", "4");
	
	float fVec[3];
	GetEntPropVector(iDeathModel, Prop_Send, "m_vecOrigin", fVec);
	if(!bIncap[iClient])
		fVec[2] += 10.0;// so legs dont get stuck in the floor
	
	TeleportEntity(iEntity, fVec, NULL_VECTOR, NULL_VECTOR);
	TeleportEntity(iDeathModel, fVec, NULL_VECTOR, NULL_VECTOR);
	
	DispatchSpawn(iEntity);
	ActivateEntity(iEntity);
	
	AcceptEntityInput(iEntity, "TurnOn");
	
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
	
	ScaleVector(fRagdollVelocity[iEntity], 5.0);
	iRagdollPushesLeft[iEntity] = iTickRate;
}


public void VPhysicsPush(int iEntity)
{
	if(iRagdollPushesLeft[iEntity] < 1)
	{
		SDKUnhook(iEntity, SDKHook_OnTakeDamage, ApplyRagdollForce);
		SDKUnhook(iEntity, SDKHook_VPhysicsUpdate, VPhysicsPush);
		SetEntityRenderMode(iEntity, RENDER_NORMAL);
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

bool IsFatOrBugModel(const char[] sModel)
{
	for(int i = 0; i < 12; i++)
	{
		if(StrEqual(sModel, sFatOrBugModels[i], false))
			return true;
	}
	return false;
}

public Action ShouldTransmitGlow(int iEntity, int iClient)
{
	if(bShowGlow[iClient])
		return Plugin_Continue;
	return Plugin_Handled;
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

public void RagdollPhysicsUpdatePost(int iEntity)
{
	if(!IsValidEntRef(iRagdollRef[iEntity]))
		return;
	
	CheckDeathModelTeleport(iEntity, iRagdollRef[iEntity]);
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

public void OnClientPutInServer(int iClient)
{
	if(IsFakeClient(iClient))
		return;
	
	SDKHook(iClient, SDKHook_OnTakeDamageAlivePost, eOnTakeDamagePost);
}

public void eOnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype, int weapon, const float damageForce[3], const float damagePosition[3])
{
	if(GetEntProp(victim, Prop_Send, "m_isIncapacitated", 1) && !GetEntProp(victim, Prop_Send, "m_isHangingFromLedge", 1))
		bIncap[victim] = true;
	else
		bIncap[victim] = false;
		
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
	SetEntProp(iEnt, Prop_Send, "m_nMinGPULevel", 1);
	SetEntProp(iEnt, Prop_Send, "m_nMaxGPULevel", 1);
	SetEntityRenderMode(iEnt, RENDER_NONE);
	SDKHook(iEnt, SDKHook_SetTransmit, ShouldTransmitGlow);
	return true;
}

public void OnEntityCreated(int iEntity, const char[] sClassname)
{
	if(sClassname[0] != 's' || !StrEqual(sClassname, "survivor_bot"))
	 	return;
	 
	SDKHook(iEntity, SDKHook_OnTakeDamageAlivePost, eOnTakeDamagePost);
}