#!/usr/bin/env python3

# Inspection copy of the worker script embedded in
# RotoMotionUSDZAnimatorPythonScript.swift. The app writes the embedded version
# into a writable export work directory before running it.

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import zipfile

from pxr import Usd, UsdGeom, UsdSkel, Gf


TARGET_CHARACTER_HEIGHT_SOURCE_UNITS = 174.0
TARGET_METERS_PER_UNIT = 0.01


def log(message):
    print(f"[rotomotion_usdz_animator] {message}")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-usdz", required=True)
    parser.add_argument("--keyframes", required=True)
    parser.add_argument("--clip-id", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--output-usdz", required=True)
    return parser.parse_args()


def unzip_usdz(source_usdz, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)

    with zipfile.ZipFile(source_usdz, "r") as archive:
        archive.extractall(dst_dir)

    candidates = []

    for root, _, files in os.walk(dst_dir):
        for filename in files:
            lower = filename.lower()
            if lower.endswith((".usd", ".usda", ".usdc")):
                candidates.append(os.path.join(root, filename))

    if not candidates:
        raise RuntimeError("No USD/USDAscii/USDCompressed file found inside USDZ.")

    candidates.sort(key=lambda path: (path.count(os.sep), path))
    root_layer = candidates[0]

    log(f"Root candidate: {root_layer}")
    return root_layer


def open_stage(root_layer_path):
    stage = Usd.Stage.Open(root_layer_path)

    if stage is None:
        raise RuntimeError(f"Could not open USD stage: {root_layer_path}")

    return stage


def find_skeleton(stage):
    skeletons = []

    for prim in stage.Traverse():
        if prim.IsA(UsdSkel.Skeleton):
            skeletons.append(UsdSkel.Skeleton(prim))

    if not skeletons:
        raise RuntimeError("No UsdSkel.Skeleton found in source USDZ.")

    if len(skeletons) > 1:
        log(f"Warning: found {len(skeletons)} skeletons; using first: {skeletons[0].GetPath()}")

    return skeletons[0]


def leaf_name(path):
    text = str(path)

    if "/" in text:
        return text.split("/")[-1]

    if ":" in text:
        return text.split(":")[-1]

    return text


def safe_prim_token(value):
    return "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in value)


def load_keyframes(path):
    with open(path, "r") as handle:
        data = json.load(handle)

    if not isinstance(data, dict):
        raise RuntimeError("Keyframes JSON must be a top-level object.")

    cleaned = {}

    for joint, keys in data.items():
        if not isinstance(joint, str):
            raise RuntimeError("Joint key must be string.")

        if not isinstance(keys, list):
            raise RuntimeError(f"Joint {joint} value must be an array.")

        cleaned_keys = []

        for key in keys:
            if not isinstance(key, list) or len(key) != 8:
                raise RuntimeError(f"Invalid key for {joint}: expected Euler array length 8.")

            cleaned_keys.append([
                int(key[0]),
                float(key[1]),
                float(key[2]),
                float(key[3]),
                float(key[4]),
                float(key[5]),
                float(key[6]),
                str(key[7]),
            ])

        cleaned[joint] = sorted(cleaned_keys, key=lambda item: item[0])

    return cleaned


def euler_radians_to_quatf(rx, ry, rz):
    x = float(rx)
    y = float(ry)
    z = float(rz)

    qx = Gf.Quatf(math.cos(x * 0.5), Gf.Vec3f(math.sin(x * 0.5), 0, 0))
    qy = Gf.Quatf(math.cos(y * 0.5), Gf.Vec3f(0, math.sin(y * 0.5), 0))
    qz = Gf.Quatf(math.cos(z * 0.5), Gf.Vec3f(0, 0, math.sin(z * 0.5)))

    return qx * qy * qz


def build_times(keyframes):
    times = set()

    for keys in keyframes.values():
        for key in keys:
            times.add(int(key[0]))

    if not times:
        times.add(1)

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


def vec3f(x, y, z):
    return Gf.Vec3f(float(x), float(y), float(z))


def vec_add(a, b):
    return vec3f(a[0] + b[0], a[1] + b[1], a[2] + b[2])


def vec_sub(a, b):
    return vec3f(a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vec_scale(value, scale):
    return vec3f(value[0] * scale, value[1] * scale, value[2] * scale)


def vec_length(value):
    return math.sqrt(
        float(value[0]) ** 2 +
        float(value[1]) ** 2 +
        float(value[2]) ** 2
    )


def vec_normalized(value, fallback):
    length = vec_length(value)

    if length < 0.000001:
        return fallback

    return vec_scale(value, 1.0 / length)


def attr_value_at_base_time(attr):
    times = attr.GetTimeSamples()

    if times:
        return attr.Get(times[0])

    return attr.Get()


def aligned_animation_values(anim, joint_paths, attr, fallback_values):
    values = attr_value_at_base_time(attr)

    if not values:
        return list(fallback_values)

    anim_joints = anim.GetJointsAttr().Get() or joint_paths
    by_full_path = {}
    by_leaf = {}

    for index, joint in enumerate(anim_joints):
        if index >= len(values):
            break

        by_full_path[str(joint)] = values[index]
        by_leaf[leaf_name(joint)] = values[index]

    aligned = []

    for index, joint in enumerate(joint_paths):
        value = by_full_path.get(str(joint))

        if value is None:
            value = by_leaf.get(leaf_name(joint))

        if value is None:
            value = fallback_values[index]

        aligned.append(value)

    return aligned


def find_base_animation(stage, skeleton):
    rel = skeleton.GetPrim().GetRelationship("skel:animationSource")

    if rel:
        for target in rel.GetTargets():
            if "RotoMotionAnim_" in str(target):
                continue

            prim = stage.GetPrimAtPath(target)

            if prim and prim.IsA(UsdSkel.Animation):
                return UsdSkel.Animation(prim)

    skeleton_parent_path = skeleton.GetPrim().GetParent().GetPath()

    for prim in stage.Traverse():
        if not prim.IsA(UsdSkel.Animation):
            continue

        if "RotoMotionAnim_" in str(prim.GetPath()):
            continue

        if str(prim.GetPath()).startswith(str(skeleton_parent_path)):
            return UsdSkel.Animation(prim)

    return None


def source_base_transforms(stage, skeleton, joint_paths):
    rest = skeleton.GetRestTransformsAttr().Get() or []

    if len(rest) < len(joint_paths):
        raise RuntimeError("Skeleton restTransforms are missing or shorter than joints.")

    rest_translations = [
        Gf.Vec3f(matrix.ExtractTranslation())
        for matrix in rest[:len(joint_paths)]
    ]

    rest_rotations = [
        Gf.Quatf(matrix.ExtractRotationQuat())
        for matrix in rest[:len(joint_paths)]
    ]

    rest_scales = [
        Gf.Vec3h(1, 1, 1)
        for _ in joint_paths
    ]

    base_anim = find_base_animation(stage, skeleton)

    if base_anim:
        log(f"Using source base animation for skeletal offsets: {base_anim.GetPrim().GetPath()}")

        return (
            aligned_animation_values(
                base_anim,
                joint_paths,
                base_anim.GetTranslationsAttr(),
                rest_translations,
            ),
            aligned_animation_values(
                base_anim,
                joint_paths,
                base_anim.GetRotationsAttr(),
                rest_rotations,
            ),
            aligned_animation_values(
                base_anim,
                joint_paths,
                base_anim.GetScalesAttr(),
                rest_scales,
            ),
        )

    log("Using skeleton rest transforms for skeletal offsets.")

    return (rest_translations, rest_rotations, rest_scales)


def source_rest_height_source_units(skeleton, joint_paths):
    rest = skeleton.GetRestTransformsAttr().Get() or []

    if len(rest) < len(joint_paths):
        return TARGET_CHARACTER_HEIGHT_SOURCE_UNITS

    world = {}
    min_z = float("inf")
    max_z = -float("inf")

    for index, joint_path in enumerate(joint_paths):
        path = str(joint_path)
        parent = "/".join(path.split("/")[:-1])
        matrix = rest[index]

        if parent and parent in world:
            world_matrix = world[parent] * matrix
        else:
            world_matrix = matrix

        world[path] = world_matrix
        translation = world_matrix.ExtractTranslation()
        min_z = min(min_z, float(translation[2]))
        max_z = max(max_z, float(translation[2]))

    height = max_z - min_z

    if not math.isfinite(height) or height <= 0.0001:
        return TARGET_CHARACTER_HEIGHT_SOURCE_UNITS

    return height


def parent_leaf_by_joint(joint_paths):
    result = {}

    for joint_path in joint_paths:
        parts = str(joint_path).replace(":", "/").split("/")
        result[leaf_name(joint_path)] = parts[-2] if len(parts) > 1 else None

    return result


def has_marker_translation_targets(keyframes):
    for keys in keyframes.values():
        for key in keys:
            _, tx, _ty, tz, rx, ry, rz, _curve = key

            if abs(rx) + abs(ry) + abs(rz) > 0.0001:
                continue

            if 0.0 <= tx <= 1.0 and 0.0 <= tz <= 1.0:
                return True

    return False


def marker_position_from_key(key):
    _, tx, _ty, tz, _rx, _ry, _rz, _curve = key

    return vec3f(
        (tx - 0.5) * TARGET_CHARACTER_HEIGHT_SOURCE_UNITS,
        0.0,
        (tz - 0.5) * TARGET_CHARACTER_HEIGHT_SOURCE_UNITS,
    )


def reference_marker_positions(keyframes):
    result = {}

    for joint, keys in keyframes.items():
        for key in keys:
            if key[8] is None:
                result[joint] = marker_position_from_key(key)
                break

    return result


def marker_positions_for_frame(keyframes, frame):
    result = {}

    for joint, keys in keyframes.items():
        key = sample_joint_at_frame(keys, frame)

        if key[8] is None:
            result[joint] = marker_position_from_key(key)

    return result


def solve_marker_translations(
    frame,
    keyframes,
    joint_paths,
    base_translations,
    reference_markers,
):
    parents = parent_leaf_by_joint(joint_paths)
    markers = marker_positions_for_frame(keyframes, frame)
    translations = list(base_translations)
    world_positions = {}

    for index, joint_path in enumerate(joint_paths):
        joint = leaf_name(joint_path)
        parent = parents.get(joint)
        base_local = base_translations[index]

        if parent is None:
            reference = reference_markers.get(joint)
            current = markers.get(joint)

            if reference is not None and current is not None:
                translations[index] = vec_add(
                    base_local,
                    vec_sub(current, reference),
                )
            else:
                translations[index] = base_local

            world_positions[joint] = translations[index]
            continue

        parent_world = world_positions.get(parent)

        if parent_world is None:
            translations[index] = base_local
            world_positions[joint] = translations[index]
            continue

        parent_marker = markers.get(parent)
        child_marker = markers.get(joint)
        bone_length = max(vec_length(base_local), 0.0001)

        if parent_marker is not None and child_marker is not None:
            marker_delta = vec_sub(child_marker, parent_marker)
            desired = vec3f(marker_delta[0], base_local[1], marker_delta[2])
            fallback = vec_normalized(base_local, vec3f(0.0, 0.0, 1.0))
            translations[index] = vec_scale(
                vec_normalized(desired, fallback),
                bone_length,
            )
        else:
            translations[index] = base_local

        world_positions[joint] = vec_add(parent_world, translations[index])

    return translations


def create_animation(stage, skeleton, keyframes, clip_id):
    joint_paths = skeleton.GetJointsAttr().Get()

    if not joint_paths:
        raise RuntimeError("Skeleton has no joints attribute.")

    joint_leaf_to_index = {
        leaf_name(joint_path): index
        for index, joint_path in enumerate(joint_paths)
    }

    log(f"Skeleton joint count: {len(joint_paths)}")
    log(f"Skeleton joints: {[leaf_name(joint) for joint in joint_paths]}")

    missing = [joint for joint in keyframes.keys() if joint not in joint_leaf_to_index]

    if missing:
        log(f"Warning: keyframed joints missing in skeleton and will be ignored: {missing}")

    anim_path = skeleton.GetPrim().GetPath().AppendChild(
        f"RotoMotionAnim_{safe_prim_token(clip_id)}"
    )

    if stage.GetPrimAtPath(anim_path):
        stage.RemovePrim(anim_path)

    anim = UsdSkel.Animation.Define(stage, anim_path)
    anim.CreateJointsAttr(joint_paths)

    times = build_times(keyframes)
    translations_attr = anim.CreateTranslationsAttr()
    rotations_attr = anim.CreateRotationsAttr()
    scales_attr = anim.CreateScalesAttr()

    base_translations, base_rotations, base_scales = source_base_transforms(
        stage,
        skeleton,
        joint_paths,
    )
    source_height = source_rest_height_source_units(skeleton, joint_paths)
    character_scale = TARGET_CHARACTER_HEIGHT_SOURCE_UNITS / source_height
    base_translations = [
        vec_scale(translation, character_scale)
        for translation in base_translations
    ]
    marker_targets_enabled = has_marker_translation_targets(keyframes)
    reference_markers = reference_marker_positions(keyframes) if marker_targets_enabled else {}

    log(
        "Character scale from source skeleton: "
        f"sourceHeight={source_height:.4f}, "
        f"targetHeight={TARGET_CHARACTER_HEIGHT_SOURCE_UNITS:.4f}, "
        f"scale={character_scale:.6f}, "
        f"markerSolve={marker_targets_enabled}"
    )

    for frame in times:
        if marker_targets_enabled:
            translations = solve_marker_translations(
                frame,
                keyframes,
                joint_paths,
                base_translations,
                reference_markers,
            )
        else:
            translations = list(base_translations)

        rotations = list(base_rotations)
        scales = list(base_scales)

        for joint, keys in keyframes.items():
            if joint not in joint_leaf_to_index:
                continue

            index = joint_leaf_to_index[joint]
            key = sample_joint_at_frame(keys, frame)
            _, _tx, _ty, _tz, rx, ry, rz, _curve = key

            if abs(rx) + abs(ry) + abs(rz) > 0.0001:
                rotations[index] = euler_radians_to_quatf(rx, ry, rz)

        translations_attr.Set(translations, Usd.TimeCode(frame))
        rotations_attr.Set(rotations, Usd.TimeCode(frame))
        scales_attr.Set(scales, Usd.TimeCode(frame))

    skeleton.GetPrim().CreateRelationship("skel:animationSource").SetTargets([
        anim.GetPrim().GetPath()
    ])

    stage.SetStartTimeCode(min(times))
    stage.SetEndTimeCode(max(times))
    source_fps = stage.GetFramesPerSecond() or 24
    source_time_codes = stage.GetTimeCodesPerSecond() or source_fps

    stage.SetFramesPerSecond(source_fps)
    stage.SetTimeCodesPerSecond(source_time_codes)
    UsdGeom.SetStageMetersPerUnit(stage, TARGET_METERS_PER_UNIT)

    log(f"Created animation: {anim.GetPrim().GetPath()}")
    log(f"Time range: {min(times)} - {max(times)}")


def save_stage_as_usdc(stage, out_path):
    stage.GetRootLayer().Export(out_path)
    log(f"Exported animated root layer: {out_path}")


def copy_non_usd_assets(source_root_layer_path, output_root_layer_path):
    source_dir = os.path.dirname(source_root_layer_path)
    output_dir = os.path.dirname(output_root_layer_path)
    copied_names = []

    for name in os.listdir(source_dir):
        lower = name.lower()

        if lower.endswith((".usd", ".usda", ".usdc")):
            continue

        src = os.path.join(source_dir, name)
        dst = os.path.join(output_dir, name)

        if os.path.exists(dst):
            if os.path.isdir(dst):
                shutil.rmtree(dst)
            else:
                os.remove(dst)

        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)

        log(f"Copied asset dependency into package work dir: {name}")
        copied_names.append(name)

    return copied_names


def package_usdz(root_usd_path, output_usdz, asset_names):
    if os.path.exists(output_usdz):
        os.remove(output_usdz)

    root_dir = os.path.dirname(root_usd_path)
    root_name = os.path.basename(root_usd_path)
    command = ["usdzip", output_usdz, "-r", root_name] + asset_names
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

    log(f"Created USDZ: {output_usdz}")


def main():
    args = parse_args()
    unpack_dir = os.path.join(args.work_dir, "unpacked")
    out_usdc = os.path.join(args.work_dir, f"{safe_prim_token(args.clip_id)}_animated.usdc")

    log(f"source_usdz = {args.source_usdz}")
    log(f"keyframes = {args.keyframes}")
    log(f"work_dir = {args.work_dir}")
    log(f"output_usdz = {args.output_usdz}")

    root_layer_path = unzip_usdz(args.source_usdz, unpack_dir)
    keyframes = load_keyframes(args.keyframes)
    stage = open_stage(root_layer_path)
    skeleton = find_skeleton(stage)

    create_animation(
        stage=stage,
        skeleton=skeleton,
        keyframes=keyframes,
        clip_id=args.clip_id,
    )

    save_stage_as_usdc(stage, out_usdc)
    asset_names = copy_non_usd_assets(root_layer_path, out_usdc)
    package_usdz(out_usdc, args.output_usdz, asset_names)
    log("DONE")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[rotomotion_usdz_animator] ERROR: {error}", file=sys.stderr)
        sys.exit(1)
