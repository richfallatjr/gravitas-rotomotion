enum RotoMotionUSDZRetargetPythonScript {
    static let contents = #"""
#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import subprocess
import sys
import zipfile

from pxr import Usd, UsdGeom, UsdSkel, Gf


ALIASES = {
    "neck": ["neck", "Neck"],
    "head_end": ["head_end", "HeadEnd", "Head_End"],
    "headfront": ["headfront", "HeadFront", "Head_Front"],
}


def log(message):
    print(f"[rotomotion_usdz_retarget] {message}")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-usdz", required=True)
    parser.add_argument("--solved-json", required=True)
    parser.add_argument("--clip-id", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--output-usdz", required=True)
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

            if len(key) == 9:
                raw_quat = key[8]

                if not isinstance(raw_quat, list) or len(raw_quat) != 4:
                    raise RuntimeError(f"Invalid quaternion for {joint_name}: expected [w, x, y, z].")

                quat = [
                    float(raw_quat[0]),
                    float(raw_quat[1]),
                    float(raw_quat[2]),
                    float(raw_quat[3]),
                ]

            cleaned_keys.append([
                int(key[0]),
                float(key[1]),
                float(key[2]),
                float(key[3]),
                float(key[4]),
                float(key[5]),
                float(key[6]),
                str(key[7]),
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

        translations_attr.Set(translations, Usd.TimeCode(frame))
        rotations_attr.Set(rotations, Usd.TimeCode(frame))
        scales_attr.Set(scales, Usd.TimeCode(frame))

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

        copied_names.append(name)

    return copied_names


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


def main():
    args = parse_args()
    unpack_dir = os.path.join(args.work_dir, "target_unpacked")
    out_usdc = os.path.join(args.work_dir, f"{safe_prim_token(args.clip_id)}_animated_target.usdc")

    log(f"target_usdz = {args.target_usdz}")
    log(f"solved_json = {args.solved_json}")
    log(f"output_usdz = {args.output_usdz}")

    root_layer_path = unzip_usdz(args.target_usdz, unpack_dir)
    stage = Usd.Stage.Open(root_layer_path)

    if stage is None:
        raise RuntimeError(f"Could not open USD stage: {root_layer_path}")

    skeleton = find_skeleton(stage)
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
    asset_names = copy_non_usd_assets(root_layer_path, out_usdc)
    package_usdz(out_usdc, args.output_usdz, asset_names)
    log("DONE")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[rotomotion_usdz_retarget] ERROR: {error}", file=sys.stderr)
        sys.exit(1)
"""#
}
