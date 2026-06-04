enum RotoMotionUSDZRetargetPythonScript {
    static let contents = #"""
#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

from pxr import Usd, UsdGeom, UsdSkel, Gf


ALIASES = {
    "neck": ["neck", "Neck"],
    "head_end": ["head_end", "HeadEnd", "Head_End"],
    "headfront": ["headfront", "HeadFront", "Head_Front"],
}

CANONICAL_JOINTS = [
    "Hips",
    "LeftUpLeg",
    "LeftLeg",
    "LeftFoot",
    "LeftToeBase",
    "RightUpLeg",
    "RightLeg",
    "RightFoot",
    "RightToeBase",
    "Spine02",
    "Spine01",
    "Spine",
    "LeftShoulder",
    "LeftArm",
    "LeftForeArm",
    "LeftHand",
    "RightShoulder",
    "RightArm",
    "RightForeArm",
    "RightHand",
    "neck",
    "Head",
    "head_end",
    "headfront",
]

BONES = [
    ("Hips", "Spine02"),
    ("Spine02", "Spine01"),
    ("Spine01", "Spine"),
    ("Spine", "neck"),
    ("neck", "Head"),
    ("Head", "head_end"),
    ("Head", "headfront"),
    ("Spine", "LeftShoulder"),
    ("LeftShoulder", "LeftArm"),
    ("LeftArm", "LeftForeArm"),
    ("LeftForeArm", "LeftHand"),
    ("Spine", "RightShoulder"),
    ("RightShoulder", "RightArm"),
    ("RightArm", "RightForeArm"),
    ("RightForeArm", "RightHand"),
    ("Hips", "LeftUpLeg"),
    ("LeftUpLeg", "LeftLeg"),
    ("LeftLeg", "LeftFoot"),
    ("LeftFoot", "LeftToeBase"),
    ("Hips", "RightUpLeg"),
    ("RightUpLeg", "RightLeg"),
    ("RightLeg", "RightFoot"),
    ("RightFoot", "RightToeBase"),
]

REST_LOCAL_METERS = {
    "Hips": (0.0, 0.0, 0.0),
    "LeftUpLeg": (-0.16, -0.10, 0.0),
    "LeftLeg": (0.0, -0.42, 0.0),
    "LeftFoot": (0.0, -0.40, 0.0),
    "LeftToeBase": (0.0, -0.05, 0.16),
    "RightUpLeg": (0.16, -0.10, 0.0),
    "RightLeg": (0.0, -0.42, 0.0),
    "RightFoot": (0.0, -0.40, 0.0),
    "RightToeBase": (0.0, -0.05, 0.16),
    "Spine02": (0.0, 0.24, 0.0),
    "Spine01": (0.0, 0.18, 0.0),
    "Spine": (0.0, 0.18, 0.0),
    "LeftShoulder": (-0.20, 0.10, 0.0),
    "LeftArm": (-0.30, -0.05, 0.0),
    "LeftForeArm": (-0.28, 0.0, 0.0),
    "LeftHand": (-0.16, 0.0, 0.0),
    "RightShoulder": (0.20, 0.10, 0.0),
    "RightArm": (0.30, -0.05, 0.0),
    "RightForeArm": (0.28, 0.0, 0.0),
    "RightHand": (0.16, 0.0, 0.0),
    "neck": (0.0, 0.16, 0.0),
    "Head": (0.0, 0.16, 0.0),
    "head_end": (0.0, 0.10, 0.0),
    "headfront": (0.0, 0.02, 0.10),
}

PARENTS = {
    "Hips": None,
    "LeftUpLeg": "Hips",
    "LeftLeg": "LeftUpLeg",
    "LeftFoot": "LeftLeg",
    "LeftToeBase": "LeftFoot",
    "RightUpLeg": "Hips",
    "RightLeg": "RightUpLeg",
    "RightFoot": "RightLeg",
    "RightToeBase": "RightFoot",
    "Spine02": "Hips",
    "Spine01": "Spine02",
    "Spine": "Spine01",
    "LeftShoulder": "Spine",
    "LeftArm": "LeftShoulder",
    "LeftForeArm": "LeftArm",
    "LeftHand": "LeftForeArm",
    "RightShoulder": "Spine",
    "RightArm": "RightShoulder",
    "RightForeArm": "RightArm",
    "RightHand": "RightForeArm",
    "neck": "Spine",
    "Head": "neck",
    "head_end": "Head",
    "headfront": "Head",
}


def log(message):
    print(f"[rotomotion_usdz_retarget] {message}")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-usdz", required=True)
    parser.add_argument("--solved-json", required=True)
    parser.add_argument("--ray-solve-reference")
    parser.add_argument("--clip-id", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--output-usdz", required=True)
    parser.add_argument("--readback-json")
    parser.add_argument("--include-hips-translation", action="store_true")
    parser.add_argument("--root-translation-scale", type=float, default=1.0)
    return parser.parse_args()


def unzip_usdz(source_usdz, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)

    with zipfile.ZipFile(source_usdz, "r") as archive:
        archive.extractall(dst_dir)

    candidates = []

    for root, _, files in os.walk(dst_dir):
        for filename in files:
            if filename.lower().endswith((".usd", ".usda", ".usdc")):
                candidates.append(os.path.join(root, filename))

    if not candidates:
        raise RuntimeError("No USD/USDAscii/USDCompressed file found inside USDZ.")

    candidates.sort(key=lambda path: (path.count(os.sep), path))
    return candidates[0]


def leaf_name(path):
    text = str(path)

    if "/" in text:
        text = text.split("/")[-1]

    if ":" in text:
        text = text.split(":")[-1]

    return text


def safe_prim_token(value):
    token = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in value)
    return token or "RotoMotionClip"


def find_skeleton(stage):
    skeletons = []

    for prim in stage.Traverse():
        if prim.IsA(UsdSkel.Skeleton):
            skeletons.append(UsdSkel.Skeleton(prim))

    if not skeletons:
        raise RuntimeError("No UsdSkel.Skeleton found in target USDZ.")

    if len(skeletons) > 1:
        log(f"Warning: found {len(skeletons)} skeletons; using first: {skeletons[0].GetPath()}")

    return skeletons[0]


def load_solved_json(path):
    with open(path, "r") as handle:
        data = json.load(handle)

    if not isinstance(data, dict):
        raise RuntimeError("Solved animation JSON must be a top-level object.")

    if "joints" in data:
        joints = data["joints"]
        fps = float(data.get("fps", 24.0))
    else:
        joints = data
        fps = 24.0

    if not isinstance(joints, dict):
        raise RuntimeError("Solved animation JSON joints must be an object.")

    cleaned = {}

    for joint_name, keys in joints.items():
        if not isinstance(joint_name, str):
            raise RuntimeError("Joint key must be string.")

        if not isinstance(keys, list):
            raise RuntimeError(f"Joint {joint_name} value must be an array.")

        cleaned_keys = []

        for key in keys:
            if not isinstance(key, list) or len(key) not in (8, 9):
                raise RuntimeError(f"Invalid key for {joint_name}: expected array length 8 or 9.")

            quat = None

            if len(key) == 9 and isinstance(key[8], str):
                # Quaternion-safe format:
                # [frame, tx, ty, tz, qw, qx, qy, qz, curve]
                quat = [
                    float(key[4]),
                    float(key[5]),
                    float(key[6]),
                    float(key[7]),
                ]
                rx = 0.0
                ry = 0.0
                rz = 0.0
                curve = str(key[8])
            elif len(key) == 9:
                # Legacy bridge format:
                # [frame, tx, ty, tz, rx, ry, rz, curve, [qw, qx, qy, qz]]
                raw_quat = key[8]

                if not isinstance(raw_quat, list) or len(raw_quat) != 4:
                    raise RuntimeError(f"Invalid quaternion for {joint_name}: expected [w, x, y, z].")

                quat = [
                    float(raw_quat[0]),
                    float(raw_quat[1]),
                    float(raw_quat[2]),
                    float(raw_quat[3]),
                ]
                rx = float(key[4])
                ry = float(key[5])
                rz = float(key[6])
                curve = str(key[7])
            else:
                # Legacy Euler format:
                # [frame, tx, ty, tz, rx, ry, rz, curve]
                rx = float(key[4])
                ry = float(key[5])
                rz = float(key[6])
                curve = str(key[7])

            cleaned_keys.append([
                int(key[0]),
                float(key[1]),
                float(key[2]),
                float(key[3]),
                rx,
                ry,
                rz,
                curve,
                quat,
            ])

        cleaned[joint_name] = sorted(cleaned_keys, key=lambda item: item[0])

    return cleaned, fps


def build_times(keyframes):
    times = set()

    for keys in keyframes.values():
        for key in keys:
            times.add(int(key[0]))

    if not times:
        raise RuntimeError("Solved animation has no time samples.")

    return sorted(times)


def sample_joint_at_frame(keys, frame):
    for key in keys:
        if int(key[0]) == int(frame):
            return key

    previous = None

    for key in keys:
        if int(key[0]) <= int(frame):
            previous = key
        else:
            break

    return previous if previous is not None else keys[0]


def quatf_from_wxyz(values):
    return Gf.Quatf(
        float(values[0]),
        Gf.Vec3f(float(values[1]), float(values[2]), float(values[3])),
    )


def quat_dot(a, b):
    ai = a.GetImaginary()
    bi = b.GetImaginary()

    return (
        float(a.GetReal()) * float(b.GetReal()) +
        float(ai[0]) * float(bi[0]) +
        float(ai[1]) * float(bi[1]) +
        float(ai[2]) * float(bi[2])
    )


def negate_quatf(value):
    imaginary = value.GetImaginary()

    return Gf.Quatf(
        -float(value.GetReal()),
        Gf.Vec3f(
            -float(imaginary[0]),
            -float(imaginary[1]),
            -float(imaginary[2]),
        ),
    )


def euler_degrees_to_quatf(rx, ry, rz):
    import math

    x = math.radians(rx)
    y = math.radians(ry)
    z = math.radians(rz)

    qx = Gf.Quatf(math.cos(x * 0.5), Gf.Vec3f(math.sin(x * 0.5), 0, 0))
    qy = Gf.Quatf(math.cos(y * 0.5), Gf.Vec3f(0, math.sin(y * 0.5), 0))
    qz = Gf.Quatf(math.cos(z * 0.5), Gf.Vec3f(0, 0, math.sin(z * 0.5)))

    return qx * qy * qz


def vec3f(x, y, z):
    return Gf.Vec3f(float(x), float(y), float(z))


def map_keyframes_to_target_joints(joint_paths, keyframes):
    exact = {}
    lower = {}

    for index, joint_path in enumerate(joint_paths):
        leaf = leaf_name(joint_path)
        exact[leaf] = index
        lower[leaf.lower()] = index

    result = {}

    for canonical_name in keyframes.keys():
        candidates = [canonical_name] + ALIASES.get(canonical_name, [])
        matched_index = None

        for candidate in candidates:
            if candidate in exact:
                matched_index = exact[candidate]
                break

            lowered = candidate.lower()
            if lowered in lower:
                matched_index = lower[lowered]
                break

        if matched_index is not None:
            result[canonical_name] = matched_index

    if not result:
        raise RuntimeError("No solved Meshy24 joints matched the target skeleton.")

    missing = sorted(set(keyframes.keys()) - set(result.keys()))

    if missing:
        log(f"Warning: solved joints missing in target skeleton and ignored: {missing}")

    return result


def base_transforms(skeleton, joint_paths):
    rest = list(skeleton.GetRestTransformsAttr().Get() or [])

    if len(rest) < len(joint_paths):
        raise RuntimeError("Skeleton restTransforms are missing or shorter than joints.")

    translations = [
        Gf.Vec3f(matrix.ExtractTranslation())
        for matrix in rest[:len(joint_paths)]
    ]
    rotations = [
        Gf.Quatf(matrix.ExtractRotationQuat())
        for matrix in rest[:len(joint_paths)]
    ]
    scales = [
        Gf.Vec3h(1, 1, 1)
        for _ in joint_paths
    ]

    return translations, rotations, scales


def create_animation(
    stage,
    skeleton,
    keyframes,
    clip_id,
    include_hips_translation,
    root_translation_scale,
    fps,
):
    joint_paths = list(skeleton.GetJointsAttr().Get() or [])

    if not joint_paths:
        raise RuntimeError("Skeleton has no joints attribute.")

    joint_map = map_keyframes_to_target_joints(joint_paths, keyframes)
    base_translations, base_rotations, base_scales = base_transforms(skeleton, joint_paths)
    times = build_times(keyframes)
    meters_per_unit = float(UsdGeom.GetStageMetersPerUnit(stage) or 1.0)

    anim_path = skeleton.GetPrim().GetParent().GetPath().AppendChild(
        f"RotoMotionAnim_{safe_prim_token(clip_id)}"
    )

    if stage.GetPrimAtPath(anim_path):
        stage.RemovePrim(anim_path)

    anim = UsdSkel.Animation.Define(stage, anim_path)
    anim.CreateJointsAttr(joint_paths)

    translations_attr = anim.CreateTranslationsAttr()
    rotations_attr = anim.CreateRotationsAttr()
    scales_attr = anim.CreateScalesAttr()
    previous_rotations = None

    for frame in times:
        translations = list(base_translations)
        rotations = list(base_rotations)
        scales = list(base_scales)

        for canonical_name, target_index in joint_map.items():
            key = sample_joint_at_frame(keyframes[canonical_name], frame)
            _frame, tx_m, ty_m, tz_m, rx, ry, rz, _curve, quat = key

            if canonical_name == "Hips" and include_hips_translation:
                root_delta_stage_units = vec3f(
                    tx_m * root_translation_scale / meters_per_unit,
                    ty_m * root_translation_scale / meters_per_unit,
                    tz_m * root_translation_scale / meters_per_unit,
                )
                translations[target_index] = translations[target_index] + root_delta_stage_units

            if quat is not None:
                delta_rotation = quatf_from_wxyz(quat)
                rotations[target_index] = base_rotations[target_index] * delta_rotation
            elif abs(rx) + abs(ry) + abs(rz) > 0.0001:
                delta_rotation = euler_degrees_to_quatf(rx, ry, rz)
                rotations[target_index] = base_rotations[target_index] * delta_rotation

        if previous_rotations is not None:
            rotations = [
                negate_quatf(rotation)
                if quat_dot(previous_rotations[index], rotation) < 0
                else rotation
                for index, rotation in enumerate(rotations)
            ]

        translations_attr.Set(translations, Usd.TimeCode(frame))
        rotations_attr.Set(rotations, Usd.TimeCode(frame))
        scales_attr.Set(scales, Usd.TimeCode(frame))
        previous_rotations = list(rotations)

    skeleton.GetPrim().CreateRelationship("skel:animationSource").SetTargets([
        anim.GetPrim().GetPath()
    ])

    stage.SetStartTimeCode(min(times))
    stage.SetEndTimeCode(max(times))
    stage.SetFramesPerSecond(fps)
    stage.SetTimeCodesPerSecond(fps)

    log(f"Created animation: {anim.GetPrim().GetPath()}")
    log(f"Matched joints: {len(joint_map)} / {len(keyframes)}")
    log(f"Time range: {min(times)} - {max(times)} at {fps:.3f} fps")


def save_stage_as_usdc(stage, out_path):
    stage.GetRootLayer().Export(out_path)
    log(f"Exported animated root layer: {out_path}")


def collect_non_usd_assets(root_layer_path):
    root_dir = os.path.dirname(root_layer_path)
    asset_names = []

    for name in os.listdir(root_dir):
        lower = name.lower()

        if lower.endswith((".usd", ".usda", ".usdc")):
            continue

        asset_names.append(name)

    return sorted(asset_names)


def package_usdz(root_usd_path, output_usdz, asset_names):
    usdzip = shutil.which("usdzip")

    if usdzip is None:
        raise RuntimeError("usdzip is missing.")

    if os.path.exists(output_usdz):
        os.remove(output_usdz)

    root_dir = os.path.dirname(root_usd_path)
    root_name = os.path.basename(root_usd_path)
    command = [usdzip, output_usdz, "-r", root_name] + asset_names
    log(f"Running: {' '.join(command)}")

    result = subprocess.run(
        command,
        cwd=root_dir,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"usdzip failed\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )


def load_ray_solve_reference(path, stage):
    if not path:
        raise RuntimeError("Target USDZ has no UsdSkel.Skeleton and no ray_solve_reference.json was provided.")

    with open(path, "r") as handle:
        data = json.load(handle)

    frames = data.get("frames")

    if not isinstance(frames, list) or not frames:
        raise RuntimeError("ray_solve_reference.json has no frames.")

    scene_units_per_meter = max(float(data.get("sceneUnitsPerMeter", 1.0)), 0.0001)
    target_height_meters = max(float(data.get("targetHeightMeters", 1.74)), 0.0001)
    meters_per_unit = float(UsdGeom.GetStageMetersPerUnit(stage) or 1.0)
    position_scale = 1.0 / scene_units_per_meter / max(meters_per_unit, 0.0001)

    positions = {joint: [] for joint in CANONICAL_JOINTS}
    rotations = {joint: [] for joint in CANONICAL_JOINTS}
    root_translation_stage_units = []
    frame_times = []
    first_hips = None

    for frame in frames:
        frame_index = int(frame.get("frame", 0))
        time_seconds = float(frame.get("timeSeconds", 0.0))
        frame_times.append((frame_index, time_seconds))
        joints = frame.get("joints", {})
        hips = joints.get("Hips", {})
        hips_position = hips.get("worldPosition") if isinstance(hips, dict) else None

        if isinstance(hips_position, list) and len(hips_position) == 3:
            if first_hips is None:
                first_hips = [
                    float(hips_position[0]),
                    float(hips_position[1]),
                    float(hips_position[2]),
                ]

            root_translation_stage_units.append([
                frame_index,
                (float(hips_position[0]) - first_hips[0]) * position_scale,
                (float(hips_position[1]) - first_hips[1]) * position_scale,
                (float(hips_position[2]) - first_hips[2]) * position_scale,
            ])
        else:
            root_translation_stage_units.append([frame_index, 0.0, 0.0, 0.0])

        for joint_name in CANONICAL_JOINTS:
            joint = joints.get(joint_name)

            if not isinstance(joint, dict):
                continue

            world_position = joint.get("worldPosition")

            if isinstance(world_position, list) and len(world_position) == 3:
                positions[joint_name].append([
                    frame_index,
                    float(world_position[0]) * position_scale,
                    float(world_position[1]) * position_scale,
                    float(world_position[2]) * position_scale,
                ])

            rotation = joint.get("localRotationWXYZ")

            if isinstance(rotation, list) and len(rotation) == 4:
                rotations[joint_name].append([
                    frame_index,
                    float(rotation[0]),
                    float(rotation[1]),
                    float(rotation[2]),
                    float(rotation[3]),
                ])

    if len(frame_times) > 1:
        first = frame_times[0]
        last = frame_times[-1]
        duration = max(last[1] - first[1], 0.0001)
        fps = float(len(frame_times) - 1) / duration
    else:
        fps = 24.0

    return {
        "schema": data.get("schema", "com.gravitas.rotomotion.ray_solve_reference.v0"),
        "frameCount": int(data.get("frameCount", len(frame_times))),
        "fps": fps,
        "positions": positions,
        "rotations": rotations,
        "rootTranslationStageUnits": root_translation_stage_units,
        "frameTimes": frame_times,
        "targetHeightMeters": target_height_meters,
        "sceneUnitsPerMeter": scene_units_per_meter,
        "metersPerUnit": meters_per_unit,
    }


def default_rest_world_meters():
    world = {}

    for joint_name in CANONICAL_JOINTS:
        local = REST_LOCAL_METERS[joint_name]
        parent = PARENTS[joint_name]

        if parent is None:
            world[joint_name] = local
            continue

        parent_position = world[parent]
        world[joint_name] = (
            parent_position[0] + local[0],
            parent_position[1] + local[1],
            parent_position[2] + local[2],
        )

    return world


def default_rest_height_meters():
    world = default_rest_world_meters()
    ys = [value[1] for value in world.values()]
    return max(max(ys) - min(ys), 0.0001)


def scaled_rest_local_stage_units(reference):
    scale = reference["targetHeightMeters"] / default_rest_height_meters()
    meters_per_unit = max(reference["metersPerUnit"], 0.0001)

    return {
        joint: (
            REST_LOCAL_METERS[joint][0] * scale / meters_per_unit,
            REST_LOCAL_METERS[joint][1] * scale / meters_per_unit,
            REST_LOCAL_METERS[joint][2] * scale / meters_per_unit,
        )
        for joint in CANONICAL_JOINTS
    }


def quat_normalized_tuple(value):
    if value is None or len(value) != 4:
        return (1.0, 0.0, 0.0, 0.0)

    w = float(value[0])
    x = float(value[1])
    y = float(value[2])
    z = float(value[3])
    length = max((w * w + x * x + y * y + z * z) ** 0.5, 0.0000001)
    return (w / length, x / length, y / length, z / length)


def rotate_vector_by_quat(vector, quat):
    # q * v * q^-1, with q in wxyz order.
    w, x, y, z = quat_normalized_tuple(quat)
    vx, vy, vz = vector

    tx = 2.0 * (y * vz - z * vy)
    ty = 2.0 * (z * vx - x * vz)
    tz = 2.0 * (x * vy - y * vx)

    return (
        vx + w * tx + (y * tz - z * ty),
        vy + w * ty + (z * tx - x * tz),
        vz + w * tz + (x * ty - y * tx),
    )


def sample_rotation(reference, joint_name, frame):
    keys = reference["rotations"].get(joint_name, [])

    if not keys:
        return (1.0, 0.0, 0.0, 0.0)

    previous = keys[0]

    for key in keys:
        if int(key[0]) == int(frame):
            return (float(key[1]), float(key[2]), float(key[3]), float(key[4]))

        if int(key[0]) <= int(frame):
            previous = key
        else:
            break

    return (float(previous[1]), float(previous[2]), float(previous[3]), float(previous[4]))


def sample_root_translation(reference, frame):
    keys = reference["rootTranslationStageUnits"]

    if not keys:
        return (0.0, 0.0, 0.0)

    previous = keys[0]

    for key in keys:
        if int(key[0]) == int(frame):
            return (float(key[1]), float(key[2]), float(key[3]))

        if int(key[0]) <= int(frame):
            previous = key
        else:
            break

    return (float(previous[1]), float(previous[2]), float(previous[3]))


def build_fk_armature_positions(reference):
    rest_local = scaled_rest_local_stage_units(reference)
    rest_world = {}

    for joint_name in CANONICAL_JOINTS:
        local = rest_local[joint_name]
        parent = PARENTS[joint_name]

        if parent is None:
            rest_world[joint_name] = local
        else:
            p = rest_world[parent]
            rest_world[joint_name] = (
                p[0] + local[0],
                p[1] + local[1],
                p[2] + local[2],
            )

    min_y = min(position[1] for position in rest_world.values())
    hip_ground_offset = -min_y
    positions = {joint: [] for joint in CANONICAL_JOINTS}

    for frame, _time_seconds in reference["frameTimes"]:
        frame_positions = {}
        root_delta = sample_root_translation(reference, frame)

        for joint_name in CANONICAL_JOINTS:
            parent = PARENTS[joint_name]

            if parent is None:
                frame_positions[joint_name] = (
                    root_delta[0],
                    hip_ground_offset + root_delta[1],
                    root_delta[2],
                )
                continue

            local = rest_local[joint_name]
            rotation = sample_rotation(reference, joint_name, frame)
            rotated_local = rotate_vector_by_quat(local, rotation)
            parent_position = frame_positions[parent]

            frame_positions[joint_name] = (
                parent_position[0] + rotated_local[0],
                parent_position[1] + rotated_local[1],
                parent_position[2] + rotated_local[2],
            )

        for joint_name, position in frame_positions.items():
            positions[joint_name].append([
                int(frame),
                float(position[0]),
                float(position[1]),
                float(position[2]),
            ])

    return positions


def create_session_armature_fallback(stage, reference_path, clip_id):
    reference = load_ray_solve_reference(reference_path, stage)
    fk_positions = build_fk_armature_positions(reference)
    reference["fkPositions"] = fk_positions
    token = safe_prim_token(clip_id)
    root_path = f"/RotoMotionSessionArmature_{token}"

    if stage.GetPrimAtPath(root_path):
        stage.RemovePrim(root_path)

    root = UsdGeom.Xform.Define(stage, root_path)
    root.GetPrim().SetDocumentation(
        "RotoMotion fallback: target USDZ had no UsdSkel.Skeleton, so this stage preserves the target and adds the animated session armature."
    )

    UsdGeom.Xform.Define(stage, f"{root_path}/Joints")
    UsdGeom.Xform.Define(stage, f"{root_path}/Bones")

    joint_radius = 0.025
    bone_width = 0.012

    for joint_name in CANONICAL_JOINTS:
        samples = fk_positions.get(joint_name, [])

        if not samples:
            continue

        joint_path = f"{root_path}/Joints/Joint_{safe_prim_token(joint_name)}"
        joint_xform = UsdGeom.Xform.Define(stage, joint_path)
        translate_op = joint_xform.AddTranslateOp()

        for sample in samples:
            frame, x, y, z = sample
            translate_op.Set(
                Gf.Vec3d(float(x), float(y), float(z)),
                Usd.TimeCode(frame),
            )

        sphere = UsdGeom.Sphere.Define(stage, f"{joint_path}/Geo")
        sphere.CreateRadiusAttr(joint_radius)
        sphere.CreateDisplayColorAttr([Gf.Vec3f(0.0, 1.0, 0.15)])

    for parent_name, child_name in BONES:
        parent_samples = {
            int(sample[0]): sample
            for sample in fk_positions.get(parent_name, [])
        }
        child_samples = {
            int(sample[0]): sample
            for sample in fk_positions.get(child_name, [])
        }
        shared_frames = sorted(set(parent_samples.keys()).intersection(child_samples.keys()))

        if not shared_frames:
            continue

        curve_path = f"{root_path}/Bones/Bone_{safe_prim_token(parent_name)}_{safe_prim_token(child_name)}"
        curve = UsdGeom.BasisCurves.Define(stage, curve_path)
        curve.CreateTypeAttr(UsdGeom.Tokens.linear)
        curve.CreateCurveVertexCountsAttr([2])
        curve.CreateWidthsAttr([bone_width, bone_width])
        points_attr = curve.CreatePointsAttr()
        curve.CreateDisplayColorAttr([Gf.Vec3f(0.0, 0.85, 0.1)])

        for frame in shared_frames:
            parent = parent_samples[frame]
            child = child_samples[frame]
            points_attr.Set(
                [
                    Gf.Vec3f(float(parent[1]), float(parent[2]), float(parent[3])),
                    Gf.Vec3f(float(child[1]), float(child[2]), float(child[3])),
                ],
                Usd.TimeCode(frame),
            )

    frames = [frame for frame, _ in reference["frameTimes"]]
    stage.SetStartTimeCode(min(frames))
    stage.SetEndTimeCode(max(frames))
    stage.SetFramesPerSecond(reference["fps"])
    stage.SetTimeCodesPerSecond(reference["fps"])

    log(
        "Target has no UsdSkel.Skeleton; created session armature fallback "
        f"from reference-height FK armature: {root_path}"
    )
    return root_path, reference


def write_session_armature_readback_json(output_json, source_usdz, armature_path, reference):
    if not output_json:
        return

    rotations = {}
    translations = {}

    for joint_name in CANONICAL_JOINTS:
        joint_rotations = reference["rotations"].get(joint_name, [])

        if joint_rotations:
            rotations[joint_name] = joint_rotations

        joint_positions = reference.get("fkPositions", reference["positions"]).get(joint_name, [])

        if joint_positions:
            translations[joint_name] = joint_positions

    payload = {
        "schema": "com.gravitas.rotomotion.animated_usdz_readback.v0",
        "sourceUSDZ": source_usdz,
        "fallbackSessionArmature": True,
        "fallbackReason": "Target USDZ had no UsdSkel.Skeleton. Export preserved target contents and added animated session armature geometry.",
        "stageFPS": float(reference["fps"]),
        "stageStartTimeCode": min(frame for frame, _ in reference["frameTimes"]),
        "stageEndTimeCode": max(frame for frame, _ in reference["frameTimes"]),
        "targetHeightMeters": float(reference["targetHeightMeters"]),
        "metersPerUnit": float(reference["metersPerUnit"]),
        "skeletonPath": armature_path,
        "skelAnimationSourceTargets": [armature_path],
        "animationPath": armature_path,
        "skeletonJoints": CANONICAL_JOINTS,
        "animationJoints": CANONICAL_JOINTS,
        "rotationSampleCount": int(reference["frameCount"]),
        "translationSampleCount": int(reference["frameCount"]),
        "scaleSampleCount": 0,
        "rotations": rotations,
        "translations": translations,
        "scales": {},
    }

    with open(output_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)

    log(f"Wrote fallback readback JSON: {output_json}")


def quat_to_array(quat):
    imaginary = quat.GetImaginary()
    return [
        float(quat.GetReal()),
        float(imaginary[0]),
        float(imaginary[1]),
        float(imaginary[2]),
    ]


def vec3_to_array(value):
    return [
        float(value[0]),
        float(value[1]),
        float(value[2]),
    ]


def find_bound_animation(stage, skeleton):
    relationship = skeleton.GetPrim().GetRelationship("skel:animationSource")
    targets = relationship.GetTargets() if relationship else []

    if not targets:
        raise RuntimeError("Skeleton has no skel:animationSource target after export.")

    animation_prim = stage.GetPrimAtPath(targets[0])

    if not animation_prim or not animation_prim.IsValid():
        raise RuntimeError(f"skel:animationSource target does not exist: {targets[0]}")

    if not animation_prim.IsA(UsdSkel.Animation):
        raise RuntimeError(f"skel:animationSource target is not a UsdSkelAnimation: {targets[0]}")

    return UsdSkel.Animation(animation_prim), [str(target) for target in targets]


def write_readback_json_from_usdz(source_usdz, output_json):
    if not output_json:
        return

    readback_dir = tempfile.mkdtemp(prefix="rotomotion_usdz_readback_")

    try:
        root_layer_path = unzip_usdz(source_usdz, readback_dir)
        stage = Usd.Stage.Open(root_layer_path)

        if stage is None:
            raise RuntimeError(f"Could not open exported USDZ for readback: {source_usdz}")

        skeleton = find_skeleton(stage)
        animation, animation_targets = find_bound_animation(stage, skeleton)

        skeleton_joints = [str(joint) for joint in (skeleton.GetJointsAttr().Get() or [])]
        animation_joints = [str(joint) for joint in (animation.GetJointsAttr().Get() or [])]

        rotations_attr = animation.GetRotationsAttr()
        translations_attr = animation.GetTranslationsAttr()
        scales_attr = animation.GetScalesAttr()

        rotation_times = rotations_attr.GetTimeSamples()
        translation_times = translations_attr.GetTimeSamples()
        scale_times = scales_attr.GetTimeSamples()

        rotations = {}
        translations = {}
        scales = {}

        for time in rotation_times:
            values = rotations_attr.Get(time) or []

            for index, joint_path in enumerate(animation_joints):
                if index >= len(values):
                    continue

                joint_name = leaf_name(joint_path)
                rotations.setdefault(joint_name, []).append([
                    int(time),
                    *quat_to_array(values[index]),
                ])

        for time in translation_times:
            values = translations_attr.Get(time) or []

            for index, joint_path in enumerate(animation_joints):
                if index >= len(values):
                    continue

                joint_name = leaf_name(joint_path)
                translations.setdefault(joint_name, []).append([
                    int(time),
                    *vec3_to_array(values[index]),
                ])

        for time in scale_times:
            values = scales_attr.Get(time) or []

            for index, joint_path in enumerate(animation_joints):
                if index >= len(values):
                    continue

                joint_name = leaf_name(joint_path)
                scales.setdefault(joint_name, []).append([
                    int(time),
                    *vec3_to_array(values[index]),
                ])

        payload = {
            "schema": "com.gravitas.rotomotion.animated_usdz_readback.v0",
            "sourceUSDZ": source_usdz,
            "rootLayer": root_layer_path,
            "stageFPS": float(stage.GetFramesPerSecond()),
            "stageStartTimeCode": float(stage.GetStartTimeCode()),
            "stageEndTimeCode": float(stage.GetEndTimeCode()),
            "skeletonPath": str(skeleton.GetPrim().GetPath()),
            "skelAnimationSourceTargets": animation_targets,
            "animationPath": str(animation.GetPrim().GetPath()),
            "skeletonJoints": skeleton_joints,
            "animationJoints": animation_joints,
            "rotationSampleCount": len(rotation_times),
            "translationSampleCount": len(translation_times),
            "scaleSampleCount": len(scale_times),
            "rotations": rotations,
            "translations": translations,
            "scales": scales,
        }

        with open(output_json, "w") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)

        log(f"Wrote readback JSON: {output_json}")
    finally:
        shutil.rmtree(readback_dir, ignore_errors=True)


def write_readback_error_json(output_json, source_usdz, error):
    if not output_json:
        return

    payload = {
        "schema": "com.gravitas.rotomotion.animated_usdz_readback.v0",
        "sourceUSDZ": source_usdz,
        "readbackFailed": True,
        "error": str(error),
    }

    with open(output_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)

    log(f"Warning: readback failed; wrote error JSON: {output_json}")


def main():
    args = parse_args()
    unpack_dir = os.path.join(args.work_dir, "target_unpacked")
    out_usdc = os.path.join(unpack_dir, f"{safe_prim_token(args.clip_id)}_animated_target.usdc")

    log(f"target_usdz = {args.target_usdz}")
    log(f"solved_json = {args.solved_json}")
    log(f"output_usdz = {args.output_usdz}")

    try:
        root_layer_path = unzip_usdz(args.target_usdz, unpack_dir)
        stage = Usd.Stage.Open(root_layer_path)

        if stage is None:
            raise RuntimeError(f"Could not open USD stage: {root_layer_path}")

        try:
            skeleton = find_skeleton(stage)
        except RuntimeError as skeleton_error:
            if "No UsdSkel.Skeleton" not in str(skeleton_error):
                raise

            armature_path, reference = create_session_armature_fallback(
                stage=stage,
                reference_path=args.ray_solve_reference,
                clip_id=args.clip_id,
            )

            save_stage_as_usdc(stage, out_usdc)
            asset_names = collect_non_usd_assets(root_layer_path)
            package_usdz(out_usdc, args.output_usdz, asset_names)
            write_session_armature_readback_json(
                args.readback_json,
                args.output_usdz,
                armature_path,
                reference,
            )
            log("DONE")
            return

        keyframes, fps = load_solved_json(args.solved_json)

        create_animation(
            stage=stage,
            skeleton=skeleton,
            keyframes=keyframes,
            clip_id=args.clip_id,
            include_hips_translation=args.include_hips_translation,
            root_translation_scale=args.root_translation_scale,
            fps=fps,
        )

        save_stage_as_usdc(stage, out_usdc)
        asset_names = collect_non_usd_assets(root_layer_path)
        package_usdz(out_usdc, args.output_usdz, asset_names)

        try:
            write_readback_json_from_usdz(args.output_usdz, args.readback_json)
        except Exception as readback_error:
            write_readback_error_json(args.readback_json, args.output_usdz, readback_error)
    finally:
        shutil.rmtree(unpack_dir, ignore_errors=True)

    log("DONE")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[rotomotion_usdz_retarget] ERROR: {error}", file=sys.stderr)
        sys.exit(1)
"""#
}
