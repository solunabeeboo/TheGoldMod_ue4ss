-- creature_db.lua
-- Ground truth for every transformable creature.
-- bpClass      : exact UE class name (without _C suffix — FindFirstOf handles it)
-- displayName  : shown in the wheel UI
-- archetype    : DA_ asset name for future hook use
-- capsule      : {radius, halfHeight} in UE units
-- swimSpeed    : MaxSwimSpeed override (default player ~600)
-- gravityScale : 0 = pure swimmer, >0 = some sinking
-- camArm       : SpringArm TargetArmLength for 3rd person
-- camOffset    : {X,Y,Z} socket offset on the spring arm
-- oxygenImmune : true = skip O2 depletion tick while transformed
-- tier         : "small" | "medium" | "large" | "leviathan" (for wheel layout)
-- abilities    : table keyed by ability name, each has its own config

local CreatureDB = {}

-- Asset paths confirmed via pakstore manifest scan.
-- mesh:     /Game/Art/Creatures/... (SkeletalMesh asset — no AnimBP owner, safe)
-- idleAnim: /Game/Art/Creatures/... (UAnimSequence — raw keyframes, NO AnimBP, NO owner cast crash)
--           AnimBPs (ABP_*) are intentionally NOT used: they cast owner to UWEAIPawn on tick 1
--           and crash with null-deref on a plain SkeletalMeshActor. Raw UAnimSequences are safe.
-- bp:       /Game/Blueprints/AI/Agents/... (NOT used for spawning — UWEAIPawn BPs carry
--           UWEAIArchetypeComponent, UWEAIBehaviorTreeComponent, UWEAIControllerTicker etc.)
local _assetPaths = {
    -- small
    ["BP_FlashFish"]          = {
        mesh     = "/Game/Art/Creatures/Flashfish_01/Animation/SKM_Flashfish_01",
        idleAnim = "/Game/Art/Creatures/Flashfish_01/Animation/Flashfish_In_World/AS_FlashFish_01_InWorld_idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature014_FlashFish/BP_FlashFish",
    },
    ["BP_Halfmoon"]           = {
        mesh     = "/Game/Art/Creatures/Halfmoon_01/Mesh/SK_Halfmoon_01",
        idleAnim = "/Game/Art/Creatures/Halfmoon_01/Animation/AS_Halfmoon_01_BasicAnims_Anim_Halfmoon_01_Idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature007_Halfmoon/BP_Halfmoon",
    },
    ["BP_Pneumo"]             = {
        mesh     = "/Game/Art/Creatures/Pneumo_01/Animation/SK_Pnuemo_01",
        idleAnim = "/Game/Art/Creatures/Pneumo_01/Animation/AS_Pnuemo_01_idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature019_Pneumo/BP_Pneumo",
    },
    ["BP_SeaOlive"]           = {
        mesh     = "/Game/Art/Creatures/Seaolive_01/Animation/SKM_Seaolive_01",
        idleAnim = "/Game/Art/Creatures/Seaolive_01/Animation/AS_Seaolive_01_swim",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature006_SeaOlive/BP_SeaOlive",
    },
    ["BP_SpineyTail"]         = {
        mesh     = "/Game/Art/Creatures/Spineytail_01/Animation/SK_Spineytail_01",
        idleAnim = "/Game/Art/Creatures/Spineytail_01/Animation/AS_Spineytail_Idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature020_SpineyTail/BP_SpineyTail",
    },
    ["BP_FourEye"]            = {
        mesh     = "/Game/Art/Creatures/Foureye_01/Animation/SKM_Foureye_01",
        idleAnim = "/Game/Art/Creatures/Foureye_01/Animation/AS_Foureye_01_swim001",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature018_FourEye/BP_FourEye",
    },
    ["BP_Geordie"]            = {
        mesh     = "/Game/Art/Creatures/Geordie_01/Mesh/SK_Geordie_01",
        idleAnim = "/Game/Art/Creatures/Geordie_01/Animation/AS_Geordie_01_Idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature002_Geordie/BP_Geordie",
    },
    ["BP_ElectricGeordie"]    = {
        mesh     = "/Game/Art/Creatures/ElectricGeordie_01/Animation/SK_ElectricGeordie_01",
        idleAnim = "/Game/Art/Creatures/ElectricGeordie_01/Animation/AS_ElectricGeordie_01_Swim",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature003_ElectricGeordie/BP_ElectricGeordie",
    },
    ["BP_WaterSlug"]          = {
        mesh     = "/Game/Art/Creatures/Waterslug_01/Animation/SK_Waterslug_01",
        idleAnim = "/Game/Art/Creatures/Waterslug_01/Animation/AS_Waterslug_01_Idle001",
        bp       = "/Game/Blueprints/Items/BP_WaterSlug",
    },
    ["BP_Quadrate"]           = {
        mesh     = nil,  -- no Art/Creatures entry found in manifest
        idleAnim = nil,
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature001_Quadrate/BP_Quadrate",
    },
    -- medium
    ["BP_AnemoneCrab"]        = {
        mesh     = "/Game/Art/Creatures/Anemonecrab_01/Animation/SKM_AnemoneCrab",
        idleAnim = "/Game/Art/Creatures/Anemonecrab_01/Animation/anim_AnemoneCrab_idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature017_AnemoneCrab/BP_AnemoneCrab",
    },
    ["BP_CoralCrab"]          = {
        mesh     = "/Game/Art/Creatures/Coralcrab_01/Animation/SK_Coralcrab_01",
        idleAnim = "/Game/Art/Creatures/Coralcrab_01/Animation/AS_CoralCrab_02_Idle",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature017_CoralCrab/BP_CoralCrab",
    },
    ["BP_BlightParasite"]     = {
        mesh     = "/Game/Art/Creatures/BlightParasite_01/Animation/SKM_BlightParasite",
        idleAnim = "/Game/Art/Creatures/BlightParasite_01/Animation/AS_BlightParasite_idle_a",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature016_BlightParasite/BP_BlightParasite",
    },
    ["BP_JellyFisher"]        = {
        mesh     = "/Game/Art/Creatures/Jellyfisher_01/Animation/SKM_Jellyfisher_001",
        idleAnim = "/Game/Art/Creatures/Jellyfisher_01/Animation/AS_Jellyfisher_001idle_001",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature020_JellyFisher/BP_JellyFisher",
    },
    ["BP_JetoCaris"]          = {
        mesh     = "/Game/Art/Creatures/Jetocaris_01/SK_Jetocaris",
        idleAnim = "/Game/Art/Creatures/Jetocaris_01/Animation/AS_Jetocaris_swimIdle",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature010_JetoCaris/BP_JetoCaris",
    },
    ["BP_Epicurean"]          = {
        mesh     = "/Game/Art/Creatures/Epicurean_01/Animation/SK_Epicurean",
        idleAnim = "/Game/Art/Creatures/Epicurean_01/Animation/AS_Epicurean_idle",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature015_Epicurean/BP_Epicurean",
    },
    ["BP_Bullethead"]         = {
        mesh     = "/Game/Art/Creatures/Bullethead_01/Animation/SK_Bullethead_01",
        idleAnim = "/Game/Art/Creatures/Bullethead_01/Animation/AS_Bullethead_Armature_idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature012_Bullethead/BP_Bullethead",
    },
    ["BP_Sandspear"]          = {
        mesh     = "/Game/Art/Creatures/Sandspear_01/Adult/Animation/SKM_SandSpear_Adult_01",
        idleAnim = "/Game/Art/Creatures/Sandspear_01/Adult/Animation/AS_SandSpear_Adult_01_Hide",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature021_Sandspear/BP_Sandspear",
    },
    -- large
    ["BP_NibblerShark"]       = {
        mesh     = "/Game/Art/Creatures/NibblerShark_01/Animation/SKM_NibblerShark",
        idleAnim = "/Game/Art/Creatures/NibblerShark_01/Animation/AS_NibblerShark_Swim",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature018_NibblerShark/BP_NibblerShark",
    },
    ["BP_NeedlerShark"]       = {
        mesh     = "/Game/Art/Creatures/Needlershark_01/Mesh/SKM_Needlershark_01",
        idleAnim = "/Game/Art/Creatures/Needlershark_01/Animation/AS_Needlershark_02__swim_001",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature003_NeedlerShark/BP_NeedlerShark",
    },
    ["BP_Hammerhead"]         = {
        mesh     = "/Game/Art/Creatures/Hammerhead_01/Mesh/SK_Hammerhead_01",
        idleAnim = "/Game/Art/Creatures/Hammerhead_01/Animation/AS_Hammerhead_01_Idle",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature001_Hammerhead/BP_Hammerhead",
    },
    ["BP_Houndgar"]           = {
        mesh     = "/Game/Art/Creatures/Houndgar_01/Animation/SK_Houndgar_01",
        idleAnim = "/Game/Art/Creatures/Houndgar_01/Animation/AS_Houndgar_01_Basics_root_Idle",
        bp       = "/Game/Blueprints/AI/Agents/SmallCreature003_Houndgar/BP_Houndgar",
    },
    ["BP_TwinEel"]            = {
        mesh     = "/Game/Art/Creatures/Twineels_01/Mesh/SKM_TwinEels_01",
        idleAnim = "/Game/Art/Creatures/Twineels_01/Animation/Follower/AS_TwinEels_01_Follower_idle",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature008_TwinEel/BP_TwinEel",
    },
    ["BP_Marrowbreach"]       = {
        mesh     = "/Game/Art/Creatures/Marrowbeach_01/Mesh/SKM_Marrowbreach_01",
        idleAnim = "/Game/Art/Creatures/Marrowbeach_01/Animation/AS_MarrowBreach_Idle",
        bp       = "/Game/Blueprints/AI/Agents/LargeCreature004_Marrowbreach/BP_Marrowbreach",
    },
    -- leviathan
    ["BP_CollectorLeviathan"] = {
        mesh     = "/Game/Art/Creatures/Leviathan_01/Mesh/SKM_Leviathan_01",
        idleAnim = "/Game/Art/Creatures/Leviathan_01/Animation/AS_Leviathan_01_Horizontal_Idle",
        bp       = "/Game/Blueprints/AI/Agents/CollectorLeviathan/BP_CollectorLeviathan",
    },
    ["BP_ElusiveLeviathan"]   = {
        mesh     = "/Game/Art/Creatures/ElusiveLeviathan/SKM_ElusiveLeviathan",
        idleAnim = nil,  -- no idle anim found in manifest
        bp       = "/Game/Blueprints/AI/Agents/Prototypes/ElusiveLeviathan/BP_ElusiveLeviathan",
    },
    ["BP_DeepWingLeviathan"]  = {
        mesh     = "/Game/Art/Creatures/Deepwingbrooder_01/Animation/SKM_DeepwingBrooder_01",
        idleAnim = "/Game/Art/Creatures/Deepwingbrooder_01/Animation/AS_DeepwingBrooder_idle",
        bp       = "/Game/Blueprints/AI/Agents/DeepWingLeviathan/BP_DeepWingLeviathan",
    },
    ["BP_VoidLeviathanMother"]= {
        mesh     = "/Game/Art/Creatures/VoidLeviathan_01/Mesh/SKM_VoidLeviathan",
        idleAnim = "/Game/Art/Creatures/VoidLeviathan_01/Animation/anim_VoidLeviathan_01_idle",
        bp       = "/Game/Blueprints/AI/Agents/VoidLeviathan/BP_VoidLeviathanMother",
    },
}

CreatureDB.All = {

    -- ── DEBUG ──────────────────────────────────────────────────────────────
    -- debugOnly = true: skips mesh swap entirely, keeps human mesh in 3rd-person.
    -- Use this to confirm ToggleThirdPerson works independently of the mesh pipeline.

    DebugHuman = {
        bpClass      = "BP_DEBUG_HUMAN",
        displayName  = "DEBUG: Human 3P",
        archetype    = "",
        capsule      = { radius = 34, halfHeight = 88 },
        swimSpeed    = 600,
        gravityScale = 1.0,
        camArm       = 0,
        camOffset    = { X = 0, Y = 0, Z = 0 },
        oxygenImmune = false,
        tier         = "small",
        debugOnly    = true,   -- skip mesh swap, just enter 3rd-person with human mesh
        abilities    = {},
    },

    -- ── SMALL FAUNA ────────────────────────────────────────────────────────

    FlashFish = {
        bpClass      = "BP_FlashFish",
        displayName  = "Flash Fish",
        archetype    = "DA_FlashFishArchetype",
        capsule      = { radius = 15, halfHeight = 18 },
        swimSpeed    = 950,
        gravityScale = 0.05,
        camArm       = 140,
        camOffset    = { X = 0, Y = 0, Z = 10 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            empBurst = {
                key      = "F",
                radius   = 200,
                damage   = 5,
                cooldown = 6.0,
            },
            camoBurst = {
                key       = "R",
                speedMult = 2.5,
                duration  = 3.0,
                cooldown  = 10.0,
            },
        },
    },

    Halfmoon = {
        bpClass      = "BP_Halfmoon",
        displayName  = "Halfmoon",
        archetype    = "DA_HalfmoonArchetype",
        capsule      = { radius = 20, halfHeight = 28 },
        swimSpeed    = 800,
        gravityScale = 0.05,
        camArm       = 160,
        camOffset    = { X = 0, Y = 0, Z = 10 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            speedBurst = {
                key       = "F",
                speedMult = 3.0,
                duration  = 3.0,
                cooldown  = 8.0,
            },
            sonicBoom = {
                key      = "R",
                radius   = 300,
                force    = 1500,
                damage   = 0,
                cooldown = 10.0,
            },
        },
    },

    Pneumo = {
        bpClass      = "BP_Pneumo",
        displayName  = "Pneumo",
        archetype    = "DA_PneumoArchetype",
        capsule      = { radius = 18, halfHeight = 24 },
        swimSpeed    = 750,
        gravityScale = -0.1,
        camArm       = 150,
        camOffset    = { X = 0, Y = 0, Z = 20 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            airBurst = {
                key      = "F",
                force    = 1200,
                cooldown = 4.0,
            },
            gravitySurge = {
                key           = "R",
                targetGravity = -0.5,
                duration      = 5.0,
                cooldown      = 12.0,
            },
        },
    },

    Quadrate = {
        bpClass      = "BP_Quadrate",
        displayName  = "Quadrate",
        archetype    = "DA_QuadrateArchetype",
        capsule      = { radius = 22, halfHeight = 22 },
        swimSpeed    = 700,
        gravityScale = 0.0,
        camArm       = 160,
        camOffset    = { X = 0, Y = 0, Z = 8 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            healBite = {
                key      = "F",
                range    = 120,
                damage   = 20,
                healFrac = 0.6,
                cooldown = 3.0,
            },
            blightSpores = {
                key      = "R",
                radius   = 250,
                damage   = 8,
                pulses   = 3,
                interval = 1000,
                cooldown = 12.0,
            },
        },
    },

    SeaOlive = {
        bpClass      = "BP_SeaOlive",
        displayName  = "Sea Olive",
        archetype    = "DA_SeaOliveArchetype",
        capsule      = { radius = 14, halfHeight = 20 },
        swimSpeed    = 680,
        gravityScale = 0.05,
        camArm       = 130,
        camOffset    = { X = 0, Y = 0, Z = 8 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            jetDash = {
                key      = "F",
                force    = 2000,
                duration = 0.4,
                cooldown = 4.0,
            },
            camoBurst = {
                key       = "R",
                speedMult = 2.0,
                duration  = 4.0,
                cooldown  = 12.0,
            },
        },
    },

    SpineyTail = {
        bpClass      = "BP_SpineyTail",
        displayName  = "Spineytail",
        archetype    = "DA_SpineyTailArchetype",
        capsule      = { radius = 18, halfHeight = 35 },
        swimSpeed    = 820,
        gravityScale = 0.0,
        camArm       = 170,
        camOffset    = { X = 0, Y = 0, Z = 12 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            tailSpin = {
                key       = "F",
                radius    = 150,
                damage    = 18,
                knockback = 800,
                cooldown  = 3.5,
            },
            speedBurst = {
                key       = "R",
                speedMult = 2.5,
                duration  = 2.5,
                cooldown  = 8.0,
            },
        },
    },

    FourEye = {
        bpClass      = "BP_FourEye",
        displayName  = "Four-Eye",
        archetype    = "DA_FourEyeArchetype",
        capsule      = { radius = 16, halfHeight = 22 },
        swimSpeed    = 760,
        gravityScale = 0.0,
        camArm       = 145,
        camOffset    = { X = 0, Y = 0, Z = 10 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            empBurst = {
                key      = "F",
                radius   = 350,
                damage   = 5,
                cooldown = 8.0,
            },
            sonicBoom = {
                key      = "R",
                radius   = 400,
                force    = 1200,
                damage   = 0,
                cooldown = 12.0,
            },
        },
    },

    Geordie = {
        bpClass      = "BP_Geordie",
        displayName  = "Geordie",
        archetype    = "DA_GeordieArchetype",
        capsule      = { radius = 24, halfHeight = 30 },
        swimSpeed    = 870,
        gravityScale = 0.0,
        camArm       = 180,
        camOffset    = { X = 0, Y = 0, Z = 14 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            jetDash = {
                key      = "F",
                force    = 2200,
                duration = 0.35,
                cooldown = 3.5,
            },
            blightSpores = {
                key      = "R",
                radius   = 200,
                damage   = 6,
                pulses   = 3,
                interval = 1000,
                cooldown = 12.0,
            },
        },
    },

    ElectricGeordie = {
        bpClass      = "BP_ElectricGeordie",
        displayName  = "Electric Geordie",
        archetype    = "DA_ElectricGeordieArchetype",
        capsule      = { radius = 24, halfHeight = 30 },
        swimSpeed    = 900,
        gravityScale = 0.0,
        camArm       = 180,
        camOffset    = { X = 0, Y = 0, Z = 14 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            electricPulse = {
                key      = "F",
                radius   = 250,
                damage   = 20,
                cooldown = 5.0,
            },
            empBurst = {
                key      = "R",
                radius   = 300,
                damage   = 5,
                cooldown = 8.0,
            },
        },
    },

    WaterSlug = {
        bpClass      = "BP_WaterSlug",
        displayName  = "Water Slug",
        archetype    = "DA_WaterSlugArchetype",
        capsule      = { radius = 20, halfHeight = 16 },
        swimSpeed    = 500,
        gravityScale = 0.2,
        camArm       = 160,
        camOffset    = { X = 0, Y = 0, Z = 6 },
        oxygenImmune = true,
        tier         = "small",
        abilities    = {
            slimeTrail = { passive = true, aggroLossDelay = 4.0 },
        },
    },

    -- ── MEDIUM FAUNA ───────────────────────────────────────────────────────

    AnemoneCrab = {
        bpClass      = "BP_AnemoneCrab",
        displayName  = "Anemone Crab",
        archetype    = "DA_AnemoneCrabArchetype",
        capsule      = { radius = 40, halfHeight = 50 },
        swimSpeed    = 650,
        gravityScale = 0.3,
        camArm       = 260,
        camOffset    = { X = 0, Y = 0, Z = 20 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            blightSpores = {
                key      = "F",
                radius   = 280,
                damage   = 10,
                pulses   = 3,
                interval = 1000,
                cooldown = 10.0,
            },
            camoBurst = {
                key       = "R",
                speedMult = 2.0,
                duration  = 3.5,
                cooldown  = 14.0,
            },
        },
    },

    CoralCrab = {
        bpClass      = "BP_CoralCrab",
        displayName  = "Coral Crab",
        archetype    = "DA_CoralCrabArchetype",
        capsule      = { radius = 35, halfHeight = 40 },
        swimSpeed    = 600,
        gravityScale = 0.25,
        camArm       = 240,
        camOffset    = { X = 0, Y = 0, Z = 18 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            ramStrike = {
                key      = "F",
                force    = 3500,
                range    = 500,
                damage   = 40,
                cooldown = 4.5,
            },
            sonicBoom = {
                key      = "R",
                radius   = 350,
                force    = 1800,
                damage   = 0,
                cooldown = 10.0,
            },
        },
    },

    BlightParasite = {
        bpClass      = "BP_BlightParasite",
        displayName  = "Blight Parasite",
        archetype    = "DA_BlightParasiteArchetype",
        capsule      = { radius = 22, halfHeight = 28 },
        swimSpeed    = 1100,
        gravityScale = 0.0,
        camArm       = 200,
        camOffset    = { X = 0, Y = 0, Z = 12 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            blightSpores = {
                key      = "F",
                radius   = 300,
                damage   = 12,
                pulses   = 3,
                interval = 1000,
                cooldown = 8.0,
            },
            phase = {
                key      = "R",
                duration = 3.0,
                cooldown = 12.0,
            },
        },
    },

    JellyFisher = {
        bpClass      = "BP_JellyFisher",
        displayName  = "Jellyfisher",
        archetype    = "DA_JellyFisherArchetype",
        capsule      = { radius = 38, halfHeight = 55 },
        swimSpeed    = 550,
        gravityScale = -0.05,
        camArm       = 270,
        camOffset    = { X = 0, Y = 0, Z = 30 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            tailSpin = {
                key       = "F",
                radius    = 220,
                damage    = 22,
                knockback = 700,
                cooldown  = 3.0,
            },
            electricPulse = {
                key      = "R",
                radius   = 280,
                damage   = 15,
                cooldown = 8.0,
            },
        },
    },

    JetoCaris = {
        bpClass      = "BP_JetoCaris",
        displayName  = "Jetocaris",
        archetype    = "DA_JetoCaris_Archetype",
        capsule      = { radius = 30, halfHeight = 45 },
        swimSpeed    = 1300,
        gravityScale = 0.0,
        camArm       = 230,
        camOffset    = { X = 0, Y = 0, Z = 16 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            jetDash = {
                key      = "F",
                force    = 2500,
                duration = 0.4,
                cooldown = 3.0,
            },
            sonicBoom = {
                key      = "R",
                radius   = 400,
                force    = 2200,
                damage   = 10,
                cooldown = 9.0,
            },
        },
    },

    Epicurean = {
        bpClass      = "BP_Epicurean",
        displayName  = "Epicurean",
        archetype    = "DA_Epicurean_Archetype",
        capsule      = { radius = 32, halfHeight = 42 },
        swimSpeed    = 700,
        gravityScale = 0.0,
        camArm       = 240,
        camOffset    = { X = 0, Y = 0, Z = 16 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            healBite = {
                key      = "F",
                range    = 180,
                damage   = 30,
                healFrac = 0.75,
                cooldown = 2.5,
            },
            ramCharge = {
                key      = "R",
                force    = 2800,
                range    = 700,
                damage   = 45,
                cooldown = 6.0,
            },
        },
    },

    Bullethead = {
        bpClass      = "BP_Bullethead",
        displayName  = "Bullethead",
        archetype    = "DA_BulletheadArchetype",
        capsule      = { radius = 28, halfHeight = 38 },
        swimSpeed    = 1100,
        gravityScale = 0.0,
        camArm       = 210,
        camOffset    = { X = 0, Y = 0, Z = 12 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            ramCharge = {
                key      = "F",
                force    = 3000,
                range    = 800,
                damage   = 35,
                cooldown = 5.0,
            },
            speedBurst = {
                key       = "R",
                speedMult = 3.5,
                duration  = 3.0,
                cooldown  = 10.0,
            },
        },
    },

    Sandspear = {
        bpClass      = "BP_Sandspear",
        displayName  = "Sandspear",
        archetype    = "DA_SandspearArchetype",
        capsule      = { radius = 25, halfHeight = 80 },
        swimSpeed    = 900,
        gravityScale = 0.1,
        camArm       = 250,
        camOffset    = { X = 0, Y = 0, Z = 20 },
        oxygenImmune = true,
        tier         = "medium",
        abilities    = {
            ramStrike = {
                key      = "F",
                force    = 3200,
                range    = 350,
                damage   = 45,
                cooldown = 5.0,
            },
            camoBurst = {
                key       = "R",
                speedMult = 2.5,
                duration  = 4.0,
                cooldown  = 12.0,
            },
        },
    },

    -- ── LARGE FAUNA ────────────────────────────────────────────────────────

    NibblerShark = {
        bpClass      = "BP_NibblerShark",
        displayName  = "Nibbler Shark",
        archetype    = "DA_NibblerSharkArchetype",
        capsule      = { radius = 50, halfHeight = 120 },
        swimSpeed    = 1200,
        gravityScale = 0.0,
        camArm       = 380,
        camOffset    = { X = 0, Y = 0, Z = 30 },
        oxygenImmune = true,
        tier         = "large",
        abilities    = {
            bite = {
                key      = "F",
                range    = 200,
                damage   = 45,
                cooldown = 1.2,
            },
            speedBurst = {
                key       = "R",
                speedMult = 3.0,
                duration  = 3.5,
                cooldown  = 10.0,
            },
        },
    },

    NeedlerShark = {
        bpClass      = "BP_NeedlerShark",
        displayName  = "Needler Shark",
        archetype    = "DA_NeedlerSharkArchetype",
        capsule      = { radius = 55, halfHeight = 130 },
        swimSpeed    = 1400,
        gravityScale = 0.0,
        camArm       = 420,
        camOffset    = { X = 0, Y = 0, Z = 30 },
        oxygenImmune = true,
        tier         = "large",
        abilities    = {
            needleVolley = {
                key        = "F",
                projectile = "BP_NeedlersharkProjectile",
                count      = 6,
                spread     = 15,
                cooldown   = 4.0,
            },
            ramCharge = {
                key      = "R",
                force    = 3500,
                range    = 900,
                damage   = 50,
                cooldown = 7.0,
            },
        },
    },

    Hammerhead = {
        bpClass      = "BP_Hammerhead",
        displayName  = "Hammerhead",
        archetype    = "DA_HammerheadArchetype",
        capsule      = { radius = 60, halfHeight = 140 },
        swimSpeed    = 1600,
        gravityScale = 0.0,
        camArm       = 460,
        camOffset    = { X = 0, Y = 0, Z = 35 },
        oxygenImmune = true,
        tier         = "large",
        abilities    = {
            ramStrike = {
                key      = "F",
                force    = 4000,
                range    = 600,
                damage   = 60,
                stunDur  = 1.0,
                cooldown = 4.0,
            },
            sonicBoom = {
                key      = "R",
                radius   = 500,
                force    = 2500,
                damage   = 20,
                cooldown = 12.0,
            },
        },
    },

    Houndgar = {
        bpClass      = "BP_Houndgar",
        displayName  = "Houndgar",
        archetype    = "DA_HoundgarArchetype",
        capsule      = { radius = 48, halfHeight = 110 },
        swimSpeed    = 1350,
        gravityScale = 0.0,
        camArm       = 380,
        camOffset    = { X = 0, Y = 0, Z = 28 },
        oxygenImmune = true,
        tier         = "large",
        abilities    = {
            empBurst = {
                key      = "F",
                radius   = 500,
                damage   = 10,
                cooldown = 7.0,
            },
            camoBurst = {
                key       = "R",
                speedMult = 3.0,
                duration  = 4.0,
                cooldown  = 14.0,
            },
        },
    },

    TwinEel = {
        bpClass      = "BP_TwinEel",
        displayName  = "Twin Eel",
        archetype    = "DA_TwinEels_Archetype",
        capsule      = { radius = 30, halfHeight = 180 },
        swimSpeed    = 1200,
        gravityScale = 0.0,
        camArm       = 420,
        camOffset    = { X = 0, Y = 0, Z = 40 },
        oxygenImmune = true,
        tier         = "large",
        abilities    = {
            chainLightning = {
                key      = "F",
                radius   = 500,
                damage   = 35,
                chains   = 3,
                falloff  = 0.6,
                cooldown = 4.0,
            },
            empBurst = {
                key      = "R",
                radius   = 400,
                damage   = 0,
                stunDur  = 2.0,
                cooldown = 9.0,
            },
        },
    },

    Marrowbreach = {
        bpClass      = "BP_Marrowbreach",
        displayName  = "Marrowbreach",
        archetype    = "DA_MarrowbreachArchetype",
        capsule      = { radius = 65, halfHeight = 160 },
        swimSpeed    = 1100,
        gravityScale = 0.05,
        camArm       = 500,
        camOffset    = { X = 0, Y = 0, Z = 40 },
        oxygenImmune = true,
        tier         = "large",
        abilities    = {
            healBite = {
                key      = "F",
                range    = 250,
                damage   = 65,
                healFrac = 0.5,
                cooldown = 2.0,
            },
            breachDive = {
                key         = "R",
                diveForce   = 4000,
                delay       = 1500,
                blastRadius = 500,
                blastForce  = 2000,
                damage      = 60,
                cooldown    = 15.0,
            },
        },
    },

    -- ── LEVIATHANS ─────────────────────────────────────────────────────────

    CollectorLeviathan = {
        bpClass      = "BP_CollectorLeviathan",
        displayName  = "Collector Leviathan",
        archetype    = "DA_CollectorLeviathanArchetype",
        capsule      = { radius = 100, halfHeight = 280 },
        swimSpeed    = 1800,
        gravityScale = 0.0,
        camArm       = 700,
        camOffset    = { X = 0, Y = 0, Z = 80 },
        oxygenImmune = true,
        tier         = "leviathan",
        abilities    = {
            vortex = {
                key      = "F",
                radius   = 800,
                force    = -4000,
                cooldown = 8.0,
            },
            jetDash = {
                key      = "R",
                force    = 5000,
                duration = 0.5,
                cooldown = 6.0,
            },
        },
    },

    ElusiveLeviathan = {
        bpClass      = "BP_ElusiveLeviathan",
        displayName  = "Elusive Leviathan",
        archetype    = "DA_ElusiveLeviathanArchetype",
        capsule      = { radius = 90, halfHeight = 260 },
        swimSpeed    = 2200,
        gravityScale = 0.0,
        camArm       = 700,
        camOffset    = { X = 0, Y = 0, Z = 80 },
        oxygenImmune = true,
        tier         = "leviathan",
        abilities    = {
            phase = {
                key      = "F",
                duration = 4.0,
                cooldown = 15.0,
            },
            tailSpin = {
                key       = "R",
                radius    = 500,
                damage    = 70,
                knockback = 2000,
                cooldown  = 8.0,
            },
        },
    },

    DeepWingLeviathan = {
        bpClass      = "BP_DeepWingLeviathan",
        displayName  = "Deep Wing Leviathan",
        archetype    = "DA_DeepWingLeviathanArchetype",
        capsule      = { radius = 110, halfHeight = 300 },
        swimSpeed    = 1600,
        gravityScale = -0.05,
        camArm       = 750,
        camOffset    = { X = 0, Y = 0, Z = 100 },
        oxygenImmune = true,
        tier         = "leviathan",
        abilities    = {
            sonicBoom = {
                key      = "F",
                radius   = 700,
                force    = 3500,
                damage   = 30,
                cooldown = 6.0,
            },
            gravitySurge = {
                key           = "R",
                targetGravity = -0.8,
                duration      = 6.0,
                cooldown      = 20.0,
            },
        },
    },

    VoidLeviathanMother = {
        bpClass      = "BP_VoidLeviathanMother",
        displayName  = "Void Leviathan",
        archetype    = "DA_VoidLeviathanMotherArchetype",
        capsule      = { radius = 120, halfHeight = 350 },
        swimSpeed    = 1400,
        gravityScale = 0.0,
        camArm       = 800,
        camOffset    = { X = 0, Y = 0, Z = 120 },
        oxygenImmune = true,
        tier         = "leviathan",
        abilities    = {
            sonicBoom = {
                key      = "F",
                radius   = 800,
                force    = 4000,
                damage   = 50,
                cooldown = 8.0,
            },
            vortex = {
                key      = "R",
                radius   = 1000,
                force    = -5000,
                cooldown = 15.0,
            },
        },
    },
}

-- Fast lookup by class name; inject confirmed mesh, idleAnim, and bp paths
CreatureDB.ByClass = {}
for key, data in pairs(CreatureDB.All) do
    data.key  = key
    local ap  = _assetPaths[data.bpClass]
    data.meshPath     = ap and ap.mesh     or nil
    data.idleAnimPath = ap and ap.idleAnim or nil
    data.bpPath       = ap and ap.bp       or nil
    CreatureDB.ByClass[data.bpClass]         = data
    CreatureDB.ByClass[data.bpClass .. "_C"] = data
end

return CreatureDB
