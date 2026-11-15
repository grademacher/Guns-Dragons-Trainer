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
        -- Explosive part this close to the enemy's vertical axis (cm) counts as visible from anywhere.
        explosiveCenterRadius = 15,
        -- How far above the aim point to look for a clear line over a shield (cm), and the step.
        overShieldMax = 150,
        overShieldStep = 10,
    },

    -- Loot chests outlined by "Highlight loot chests" (opened ones are skipped).
    -- EXASMaterialTreasureChest: resource chest. EXASArtifactBox: artifact box (B_LA_Artifact_Box_C).
    -- EXASSuddenEventReward: secret room / event reward chest (B_SecretRoomReward_C).
    chests = { classes = { "EXASMaterialTreasureChest", "EXASArtifactBox", "EXASSuddenEventReward" } },

    -- Experimental "Show highlights on minimap": the trainer draws its own icons (icons\*.png next to the mod,
    -- made by icons\make_icons.ps1) on the game's minimap for highlighted objects, including ones the game has
    -- no icon for or hides in unexplored areas. First matching parent class wins; others get no icon.
    minimap = {
        icons = {
            { parent = "EXASSuddenEventReward", icon = "secret_chest.png" },     -- secret room / event reward chests
            { parent = "EXASMaterialTreasureChest", icon = "chest.png" },        -- resource chests
            { parent = "EXASArtifactBox", icon = "artifact_box.png" },
            { parent = "B_MaterialGimmick_Base_C", icon = "clay_launcher.png" }, -- bone / tomb / barrel piles
            { parent = "B_SecretBreakableWall_C", icon = "secret_wall.png" },
        },
        iconSize = 27,           -- px, same as the game's badges
        poolSize = 24,           -- icon images added to the minimap once; the nearest objects use them
        namePrefix = "GDT_MinimapIcon_",
        iconWidgetClass = "W_MinimapIcon_C", -- the game's icons, used to measure the map scale
        defaultScale = 0.06,     -- px per cm (measured 2026-11-15); re-measured live from the game's icons
        defaultEdge = 184,       -- px from center where icons are pinned to the edge
        calibrateSeconds = 2,
    },

    -- Cracked secret walls outlined by "Highlight secret walls".
    secretWalls = { classes = { "B_SecretBreakableWall_C" } },

    -- Mushroom enemies (spore colony) duck into the ground and block damage. Their EXASSporeColonyComponent
    -- (property SporeColony / GetSporeColony()) has these flags while ducked.
    burrow = { componentProp = "SporeColony", flags = { "bIsBurrowed", "bIsBurrowing" } },

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
        -- Pickups pulled to you by the loot magnet when you host or play solo.
        classes = { "EXAutoCollectObject" },
        -- Per-player drops: never pulled.
        skipClasses = { EXExclusiveAutoCollectObject = true },
    },
}
