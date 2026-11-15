-- Advanced trainer configuration (game-specific names and timings).
-- Day-to-day toggles live in the trainer window and are saved to settings.ini; you normally
-- don't need to touch this file unless probe.txt shows different names in a new game build.

return {
    -- Launch TrainerGUI.exe automatically when the game starts.
    autoLaunchGui = true,
    guiExe = "TrainerGUI.exe",

    -- How often settings.ini is re-read and status.ini written (ms).
    settingsPollMs = 250,
    -- How often ammo / armor / stat changes run (ms). Health is checked every frame.
    refillIntervalMs = 100,

    -- Write probe.txt (class/property/function names this build exposes) once a level is loaded.
    writeProbe = true,

    health = {
        -- Health is refilled every frame. On top of that, this stat on your player state is set so
        -- incoming damage is scaled by (1 + value): -1 means no damage.
        -- Do NOT use gameplay tags here: adding tags through UE4SS crashes this game (UE 5.7).
        attributes = { { "Health", "MaxHealth" } },
        damageTakenStat = { set = "EXRogueLiteAttributeSet", name = "FinalReceivedDamageRatio", value = -1 },
    },

    ammo = {
        -- Stat that decides whether firing uses ammo (1 = yes). Set to 0 while infinite ammo is on.
        useAmmoStat = { set = "EXRogueLiteAttributeSet", name = "UseAmmoOnFire", value = 0 },
        magazineAmmoTag = "EX.ShooterGame.Weapon.MagazineAmmo",
        magazineSizeTag = "EX.ShooterGame.Weapon.MagazineSize",
        -- { attribute, maxAttribute } pairs on EXEnergyMagazineAttributeSet; missing names are skipped.
        energyAttributes = {
            { "Energy", "MaxEnergy" },
            { "EnergyMagazine", "MaxEnergyMagazine" },
            { "Magazine", "MaxMagazine" },
        },
    },

    armor = {
        -- Armor is the Shield attribute on the health set (EXShieldSet has no attributes in this build).
        set = "EXHealthSet",
        attributes = { { "Shield", "MaxShield" } },
    },

    -- Infinite self revives: the count under your portrait and the "revives used" counter.
    revives = {
        countSet = "EXRogueLiteAttributeSet",
        countAttr = "NumResurrectCount",
        usedProp = "ResurrectionCount", -- on EXPlayerState
        minCount = 1,                   -- keep at least this many, even if you had none when switching it on
    },

    -- Stats on your player state's EXRogueLiteAttributeSet.
    stats = {
        set = "EXRogueLiteAttributeSet",
        dashCooldown = "DashCoolTime",        -- seconds
        dashCooldownValue = 0.05,
        dashCharges = { "RemainDashCount", "MaxDashCount" },
        fireRate = "FireRateRatio",           -- multiplier, 1 = normal
        -- Bow draw: charge speed multiplier and time to full draw (s). The fire rate cheat scales both.
        chargeSpeed = "ChargeSpeedRate",
        chargeTime = "ChargeDoneTime",
        spreadZero = { "AdditionalBulletSpreadAngle", "AdditionalSpreadMinMaxRatio" },
        lootRange = "ItemDetectionRange",     -- cm
        reloadSpeed = "ReloadSpeedRatio",     -- multiplier, 1 = normal
        bulletSpeed = "BulletSpeed",          -- cm/s, used to lead moving targets
        bulletGravity = "BulletGravity",      -- cm/s^2 (negative = drops)
    },

    -- Movement speed multiplies the pawn's CharacterMovement.MaxWalkSpeed.
    -- As a client the host may pull you back (rubber-banding).

    -- Enemy gear (EXDamageableParts attached to enemies).
    parts = {
        -- Lowercase pieces of class names that mean "explodes when shot" (goblin barrel, grenadier's grenade).
        explosivePatterns = { "barrel", "grenad", "bomb", "explos", "powder", "keg", "dynamite" },
        -- Shield actors that wrap the enemy completely (aiming over them is pointless).
        ignoreShieldClasses = { "EXASSphereShield" },
        -- Only shields this close to the target (cm) are checked.
        shieldSearchRadius = 600,
        -- Part classes to look for. Blueprint subclasses are listed too: FindAllOf on the native parent alone
        -- missed the goblins' shields (B_GoblinShield_C) in a real fight.
        classes = { "EXDamageableParts", "EXASDamageableParts", "B_DamageableParts_C", "B_GoblinShield_C",
                    "B_Goblin_Spiked_Shield_C",
                    "B_Monster_GoblinGrenadier_C", "B_GoblinBarrel_C" },
        shieldPatterns = { "shield" },
        -- Shield goblins carry their shield as a child actor component named B_GoblinShield
        -- (B_C1_Goblin_Soldier_C: B_GoblinShield_C; B_C2_Goblin_Spiked_Shield_C: B_Goblin_Spiked_Shield_C).
        -- Only the spiked one also has a ShieldComponent (bShieldBroken once broken).
        shieldComponentProp = "ShieldComponent",
        shieldActorProps = { "Shield", "B_GoblinShield" },
        -- Clearance kept around a shield (cm), and the rough height of your gun above your character's center.
        shieldMargin = 12,
        gunHeight = 40,
        -- Explosive part this close to the enemy's vertical axis (cm) counts as visible from anywhere.
        explosiveCenterRadius = 15,
        -- How far above the aim point to look for a clear line over a shield (cm), and the step.
        overShieldMax = 60,      -- any higher and the shot flies over the enemy's head too
        overShieldStep = 10,
    },

    -- Loot chests outlined by "Highlight loot chests" (opened ones are skipped).
    -- EXASMaterialTreasureChest: resource chest. EXASArtifactBox: artifact box (B_LA_Artifact_Box_C).
    -- EXASSuddenEventReward: secret room / event reward chest (B_SecretRoomReward_C).
    -- Also dynamic events (graves you stand next to to trigger a wave that drops a reward); the blueprint
    -- class is listed too because FindAllOf on a native parent can miss blueprint children.
    chests = { classes = { "EXASMaterialTreasureChest", "EXASArtifactBox", "EXASSuddenEventReward",
                           "EXASDynamicEventPoint", "BP_DynamicEvent_Grave_C" },
               eventClass = "EXASDynamicEventPoint",
               -- The reward chest (B_SuddenEventReward_Level_01_C) appears within this distance (cm) of its event.
               rewardClasses = { "EXASSuddenEventReward", "B_SuddenEventReward_C" }, eventRewardRadius = 800,
               -- Artifact boxes: players who already opened it (EXPlayerState list).
               usedListProp = "UsedPlayer" },

    -- Objects in a hidden dungeon you're not in (its sublevel stays loaded, objects inactive) are not highlighted.
    highlightSkip = { dungeonLevelMarker = "HiddenSubLevel_" },

    -- Experimental "Show highlights on minimap": the trainer draws its own icons (icons\*.png next to the mod,
    -- made by icons\make_icons.ps1) on the game's minimap for highlighted objects, including ones the game has
    -- no icon for or hides in unexplored areas. First matching parent class wins; others get no icon.
    minimap = {
        icons = {
            { parent = "EXASSuddenEventReward", icon = "secret_chest.png" },     -- secret room / event reward chests
            { parent = "EXASMaterialTreasureChest", icon = "chest.png" },        -- resource chests
            { parent = "EXASDynamicEventPoint", icon = "event_grave.png" },     -- dynamic events (graves)
            { parent = "EXASArtifactBox", icon = "artifact_box.png" },
            { parent = "B_MaterialGimmick_Base_C", icon = "clay_launcher.png" }, -- bone / tomb / barrel piles
            { parent = "B_SecretBreakableWall_C", icon = "secret_wall.png" },
        },
        iconSize = 27,           -- px, same as the game's badges
        poolSize = 24,           -- icon images added to the minimap once; the nearest objects use them
        dotPoolSize = 40,        -- extra small images for "magnet items on minimap" dots
        dotIcon = "loot_dot.png",
        dotSize = 9,             -- px
        namePrefix = "GDT_MinimapIcon_",
        iconWidgetClass = "W_MinimapIcon_C", -- the game's icons, used to measure the map scale
        defaultScale = 0.06,     -- px per cm (measured 2026-11-15); re-measured live from the game's icons
        scaleRange = { 0.5, 2 }, -- live measurements outside defaultScale x this range are ignored
        mergeDistance = 450,     -- cm; objects with the same icon closer than this share one badge (~27 px)
        maxHeightDiff = 20000,   -- cm; objects further above/below you are in another area and get no badge
        defaultEdge = 184,       -- px from center where icons are pinned to the edge
        calibrateSeconds = 2,
    },

    -- Cracked secret walls outlined by "Highlight secret walls".
    secretWalls = { classes = { "B_SecretBreakableWall_C" } },

    -- Mushroom enemies (spore colony) duck into the ground and block damage. Their EXASSporeColonyComponent
    -- (property SporeColony / GetSporeColony()) has these flags while ducked.
    -- While ducked only the hat on top (bones ElphaHat01..; HatBonePrefix on the component) takes damage, until
    -- it breaks (bHatDestroyed) and stuns the mushroom.
    burrow = { componentProp = "SporeColony", flags = { "bIsBurrowed", "bIsBurrowing" }, hatBonePrefix = "ElphaHat" },

    -- Lifeline guards: a small imp tethered to an enemy keeps it invulnerable until the imp dies.
    -- The tether is an EXASLifeLineLinkActor with SourceNPC / TargetNPC; the end whose class name
    -- contains one of these pieces is the guard.
    guards = {
        linkClass = "EXASLifeLineLinkActor",
        guardPatterns = { "lifeline", "imp" },
        -- Enemies that hold a list of monsters they protect (the Goblin Shaman Elite's Soul Binding).
        -- The holder is the guard of every monster in the list.
        binders = {
            { class = "B_C1_Goblin_Shaman_Elite_C", listProp = "SoulBindingMonsters" },
        },
        -- Casters whose shield makes other enemies invulnerable while it lasts (Troll Summoner's skill:
        -- GA_NPC_Troll_Summoner_Skill02 puts this effect actor on each shielded enemy).
        shieldCasters = {
            { casterClass = "EXASTrollSummoner", effectClass = "B_ReplicatedVFX_Troll_Summoner_Shield_C",
              attachRadius = 250 },
        },
    },

    -- Weapon spread data asset fields set to 0 while "no spread" is on (restored when turned off).
    spreadDataFields = {
        "SpreadAngleMultiplier_Aiming", "SpreadAngleMultiplier_StandingStill", "SpreadAngleMultiplier_Moving",
        "SpreadAngleMultiplier_Crouching", "SpreadAngleMultiplier_JumpingOrFalling",
    },

    aim = {
        headSockets = { "head", "Head", "head_socket", "HeadSocket", "Bip001-Head", "Bip001_Head", "neck_01" },
        headHeightFraction = 0.75,   -- fallback: this fraction of the capsule half-height along the enemy's up axis
        enemyRefreshSeconds = 0.5,   -- scanning all objects is not free
        fallbackTickMs = 8,          -- only used if per-frame game-thread loops aren't available
        -- Classes never targeted (friendly summons). Team checks catch the rest.
        ignoreClasses = { "EXASThornBloom" },
        -- Line of fire (with "line of sight" on): the aim point must be reachable from the camera and the gun
        -- without hitting terrain, walls or a shield; otherwise another point on the enemy is used.
        -- Enemy parts that take no damage (physics material tagged Gameplay.Zone.God: PhysMat_Player_Wood,
        -- _Stone, _Metal, _MagicShield), read from the physics assets 2026-11-15. Shapes are in the bone's space
        -- (cm); rot = Pitch, Yaw, Roll; box size = full X, Y, Z; capsule length = between its sphere centers.
        -- Abilities that make their enemy immune while a flag is set: the enemy is skipped meanwhile.
        immuneFlags = {
            { class = "GA_NPC_Troll_Hunter_Elite_BushAmbush_C", flag = "bAmbushDamageImmune" }, -- hiding in a bush
        },
        godZones = {
            B_C2_Troll_Tamer_C = {
                { bone = "Mask", shapes = {
                    { kind = "box", center = { 42.3, 0, 0 }, rot = { -0.6, 3.8, 8.4 }, size = { 97, 42.1, 20.1 } } } },
            },
            B_C2_Troll_Summoner_C = {
                { bone = "Bone021", shapes = {
                    { kind = "sphere", center = { 0, 2.2, -20.1 }, radius = 16.7 },
                    { kind = "sphere", center = { 0, 0, 19.8 }, radius = 15.8 },
                    { kind = "capsule", center = { 18.6, 3.1, 0.1 }, rot = { 0, -90.5, -90 }, radius = 25.1, length = 62.6 } } },
            },
        },
        lineOfFire = {
            traceChannel = 0,       -- TraceTypeQuery1 = Visibility
            pointTolerance = 25,    -- cm; a hit this close to the aim point counts as reaching it
            maxBones = 24,          -- bones tried at most per enemy type
            skipBones = { "ik_", "root", "attach", "weapon", "socket", "prop", "camera", "_end", "twist", "pole" },
            stickySeconds = 0.3,    -- prefer the last clear point for this long (no flicker)
            bodyRadiusScale = 0.8,  -- other enemies' capsules count as this wide when checking who's in the way
            godMargin = 4,          -- cm of clearance kept around damage-proof parts
            -- Fallback order when the planned point is blocked: weak spot (+ points this far around it),
            -- head (+ points around it, bones named like a head), then the rest of the body.
            weakSpotEdge = 10,      -- cm
            headEdge = 14,          -- cm
            headBones = { "head", "neck", "face", "jaw", "eye", "brow", "skull" },
            inFrontFraction = 0.95, -- a body must be before this fraction of the line to count as in the way
        },
        -- Keep a locked target this long after it goes out of sight (e.g. behind its own shield).
        stickySeconds = 1.5,
        -- Extra radius (degrees) a locked target may drift outside the aim radius before it is dropped.
        stickyExtraFov = 10,
    },

    supplies = {
        -- Classes treated as supplies (aim assist target + outline).
        -- EXASClayShootingBase: the stone/wood "clay" bubbles launched from material piles; shooting them
        -- splits them into more (B_ClayShooting_Stone_C / _Wood_C).
        -- Child classes are listed too: looking objects up by a parent class can miss child classes the game
        -- loads later (a tomb launcher was missed that way).
        classes = { "EXASClayShootingBase", "B_ClayShooting_Base_C", "B_ClayShooting_Stone_C", "B_ClayShooting_Wood_C",
                    "B_ClayShooting_ManaSpore_C" },
        -- One shot per clay: when the equipped weapon fires (its "time since last fired" resets) while aimed at
        -- a clay, move to the next clay. A clay already shot isn't picked again for retargetSeconds unless it's
        -- the only one left. If shots can't be seen, stay one shot interval (from the FireRate stat) instead.
        shotMargin = 0.03,      -- seconds added to the shot interval (fallback only)
        minDwell = 0.05, maxDwell = 0.4,
        retargetSeconds = 1.5,
        fireRateStat = "FireRate",
        -- Also outlined by "Highlight supplies" (besides supply classes): pickups and the material piles
        -- (bones, tomb, barrel) that launch the clays when shot.
        highlightPickupClasses = { "EXAutoCollectObject", "B_MaterialGimmick_Base_C", "B_MaterialGimmick_Bones_C",
                                   "B_MaterialGimmick_Tomb_C", "B_MaterialGimmick_Barrel_C" },
        -- Custom-depth stencil the game uses for its interactable outline.
        outlineStencil = 2,
    },

    -- Ping key (F8 by default): logs the object under the crosshair to pings.txt. It changes nothing in game.
    ping = {
        maxDistance = 80,   -- meters
        maxAngle = 8,       -- degrees from the crosshair to the object's center point
        -- Objects with any of these parent classes are skipped (they float in front of what you look at).
        skipParents = {
            "EXDamageDisplayActor", "EXASReplicatedVFXActor", "EXBulletBaseActor", "EXASNPCProjectile",
            "EXMonsterProjectile", "EXASThornBloomLink", "EXASLifeLineLinkActor",
            "Volume", "Info", "Light", "NiagaraActor", "Emitter", "GameplayCueNotify_Actor", "EXIndicator",
        },
        -- Exact classes skipped.
        ignoreClasses = {
            StaticMeshActor = true, InstancedFoliageActor = true, Landscape = true, WorldSettings = true,
            NiagaraActor = true, DecalActor = true, PointLight = true, SpotLight = true, RectLight = true,
            SkyLight = true, DirectionalLight = true, PostProcessVolume = true, LevelSequenceActor = true,
            CineCameraActor = true, CameraActor = true, FMODAmbientSound = true,
        },
    },

    loot = {
        -- Pickups pulled in by the loot magnet. Host / solo: moved onto you. Joined: picked up through the
        -- game's own pickup request on your character's item detection component.
        classes = { "EXAutoCollectObject" },
        detectionComponent = "ItemDetectionComponent",
        clientTries = 6,          -- requests per pickup at most (full inventory, someone else's item, ...)
        clientRetrySeconds = 0.5, -- between requests for the same pickup
        clientPerTick = 8,        -- requests per 0.1 s at most
        -- Per-player drops: never pulled.
        skipClasses = { EXExclusiveAutoCollectObject = true },
    },
}
