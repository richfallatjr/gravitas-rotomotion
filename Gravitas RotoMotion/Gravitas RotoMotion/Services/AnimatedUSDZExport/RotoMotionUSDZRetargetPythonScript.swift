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


def log(message):
    print(f"[rotomotion_existing_skeleton_export] {message}")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-usdz", required=True)
    parser.add_argument("--session-skeleton-identity", required=True)
    parser.add_argument("--solved-json", required=True)
    parser.add_argument("--clip-id", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--output-usdz", required=True)
    parser.add_argument("--preflight-json")
    parser.add_argument("--readback-json")
    parser.add_argument("--include-hips-translation", action="store_true")
    return parser.parse_args()


def unzip_usdz(source_usdz, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)

    with zipfile.ZipFile(source_usdz, "r") as archive:
        names = archive.namelist()
        archive.extractall(dst_dir)

    usd_names = [
        name for name in names
        if name.lower().endswith((".usd", ".usda", ".usdc"))
    ]

    if not usd_names:
        raise RuntimeError("No USD root file found inside USDZ.")

    # USDZ convention: the first USD file in package order is the root layer.
    root_member = usd_names[0]
    root_layer = os.path.join(dst_dir, root_member)
    log(f"USDZ root layer from archive order: {root_layer}")

    return root_layer, root_member


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


def dump_stage_prims(stage):
    prims = []
    log("Opened stage prim dump:")

    for prim in stage.Traverse():
        item = {
            "path": str(prim.GetPath()),
            "type": str(prim.GetTypeName()),
        }
        prims.append(item)
        log(f"  {item['path']} type={item['type']}")

    return prims


def write_preflight(path, data):
    if not path:
        return

    with open(path, "w") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)

    log(f"Wrote preflight JSON: {path}")


def load_session_skeleton_identity(path):
    with open(path, "r") as handle:
        data = json.load(handle)

    if data.get("schema") != "com.gravitas.rotomotion.session_skeleton_identity.v0":
        raise RuntimeError("Session skeleton identity schema mismatch.")

    return data


def get_session_skeleton(
    stage,
    identity,
    preflight_json,
    target_usdz,
    root_layer_path,
    root_member,
):
    skeleton_path = identity.get("skeletonPath")
    expected_joint_paths = identity.get("jointPaths", [])
    expected_leaves = set(identity.get("jointLeafNames", []))

    if skeleton_path:
        prim = stage.GetPrimAtPath(skeleton_path)

        if prim and prim.IsValid() and prim.IsA(UsdSkel.Skeleton):
            skeleton = UsdSkel.Skeleton(prim)
            joint_paths = list(skeleton.GetJointsAttr().Get() or [])

            log(f"Using exact session skeleton path: {skeleton_path}")
            log(f"Session/target joint count: {len(joint_paths)}")

            for index, joint_path in enumerate(joint_paths):
                log(f"  joint[{index}] {joint_path} leaf={leaf_name(joint_path)}")

            write_preflight(preflight_json, {
                "schema": "com.gravitas.rotomotion.usdz_retarget_preflight.v0",
                "target_usdz": target_usdz,
                "root_layer": root_layer_path,
                "root_layer_path_inside_usdz": root_member,
                "session_skeleton_path": skeleton_path,
                "session_joint_count": len(expected_joint_paths),
                "session_joint_paths": expected_joint_paths,
                "session_joint_leaf_names": sorted(expected_leaves),
                "skeleton_found": True,
                "target_joint_count": len(joint_paths),
                "target_joints": [str(joint_path) for joint_path in joint_paths],
                "target_joint_leaf_names": [leaf_name(joint_path) for joint_path in joint_paths],
            })

            return skeleton

        prim_dump = dump_stage_prims(stage)

        write_preflight(preflight_json, {
            "schema": "com.gravitas.rotomotion.usdz_retarget_preflight.v0",
            "target_usdz": target_usdz,
            "root_layer": root_layer_path,
            "root_layer_path_inside_usdz": root_member,
            "session_skeleton_path": skeleton_path,
            "session_joint_count": len(expected_joint_paths),
            "session_joint_paths": expected_joint_paths,
            "session_joint_leaf_names": sorted(expected_leaves),
            "skeleton_found": False,
            "resolved_prim_path": str(prim.GetPath()) if prim and prim.IsValid() else None,
            "resolved_prim_type": str(prim.GetTypeName()) if prim and prim.IsValid() else None,
            "opened_stage_prim_dump": prim_dump,
        })

        raise RuntimeError(
            "Session skeleton path was not found in target USDZ: "
            + str(skeleton_path)
        )

    candidates = []

    for prim in stage.Traverse():
        if not prim.IsA(UsdSkel.Skeleton):
            continue

        skeleton = UsdSkel.Skeleton(prim)
        joints = list(skeleton.GetJointsAttr().Get() or [])
        leaves = set(leaf_name(joint) for joint in joints)
        overlap = len(expected_leaves.intersection(leaves))
        candidates.append((overlap, skeleton, joints, leaves))

    if not candidates:
        prim_dump = dump_stage_prims(stage)

        write_preflight(preflight_json, {
            "schema": "com.gravitas.rotomotion.usdz_retarget_preflight.v0",
            "target_usdz": target_usdz,
            "root_layer": root_layer_path,
            "root_layer_path_inside_usdz": root_member,
            "session_skeleton_path": None,
            "session_joint_count": len(expected_joint_paths),
            "session_joint_paths": expected_joint_paths,
            "session_joint_leaf_names": sorted(expected_leaves),
            "skeleton_found": False,
            "opened_stage_prim_dump": prim_dump,
        })

        raise RuntimeError("No UsdSkel.Skeleton candidates found in target USDZ.")

    candidates.sort(key=lambda item: item[0], reverse=True)
    best_overlap, best_skeleton, best_joints, best_leaves = candidates[0]

    if best_overlap <= 0:
        prim_dump = dump_stage_prims(stage)

        write_preflight(preflight_json, {
            "schema": "com.gravitas.rotomotion.usdz_retarget_preflight.v0",
            "target_usdz": target_usdz,
            "root_layer": root_layer_path,
            "root_layer_path_inside_usdz": root_member,
            "session_skeleton_path": None,
            "session_joint_count": len(expected_joint_paths),
            "session_joint_paths": expected_joint_paths,
            "session_joint_leaf_names": sorted(expected_leaves),
            "skeleton_found": False,
            "best_overlap": best_overlap,
            "opened_stage_prim_dump": prim_dump,
        })

        raise RuntimeError("No target skeleton shares joint names with session skeleton.")

    log(
        f"Using best matching skeleton {best_skeleton.GetPrim().GetPath()} "
        f"with overlap {best_overlap}/{len(expected_leaves)}"
    )

    write_preflight(preflight_json, {
        "schema": "com.gravitas.rotomotion.usdz_retarget_preflight.v0",
        "target_usdz": target_usdz,
        "root_layer": root_layer_path,
        "root_layer_path_inside_usdz": root_member,
        "session_skeleton_path": None,
        "session_joint_count": len(expected_joint_paths),
        "session_joint_paths": expected_joint_paths,
        "session_joint_leaf_names": sorted(expected_leaves),
        "skeleton_found": True,
        "matched_by_joint_names": True,
        "best_overlap": best_overlap,
        "target_joint_count": len(best_joints),
        "target_joints": [str(joint_path) for joint_path in best_joints],
        "target_joint_leaf_names": sorted(best_leaves),
    })

    return best_skeleton


def find_session_skeleton_for_readback(stage, identity):
    skeleton_path = identity.get("skeletonPath")

    if not skeleton_path:
        return get_session_skeleton(
            stage=stage,
            identity=identity,
            preflight_json=None,
            target_usdz="readback",
            root_layer_path="readback",
            root_member="readback",
        )

    prim = stage.GetPrimAtPath(skeleton_path)

    if prim and prim.IsValid() and prim.IsA(UsdSkel.Skeleton):
        return UsdSkel.Skeleton(prim)

    dump_stage_prims(stage)

    raise RuntimeError(
        "Session skeleton path could not be resolved during readback: "
        + skeleton_path
    )


def load_solved_json(path):
    with open(path, "r") as handle:
        data = json.load(handle)

    if data.get("schema") != "com.gravitas.rotomotion.solved_animation.v1":
        raise RuntimeError(
            "Solved animation JSON schema mismatch. "
            "Expected com.gravitas.rotomotion.solved_animation.v1."
        )

    if data.get("rotation_order") != "wxyz":
        raise RuntimeError("Solved animation JSON must declare rotation_order=wxyz.")

    joints = data.get("joints")

    if not isinstance(joints, dict):
        raise RuntimeError("Solved animation JSON missing joints object.")

    cleaned = {}

    for joint_name, keys in joints.items():
        if not isinstance(joint_name, str):
            raise RuntimeError("Joint key must be string.")

        if not isinstance(keys, list):
            raise RuntimeError(f"Joint {joint_name} value must be an array.")

        cleaned_keys = []

        for key in keys:
            if not isinstance(key, dict):
                raise RuntimeError(f"Invalid key for {joint_name}: expected object.")

            rotation = key.get("rotation_wxyz")

            if not isinstance(rotation, list) or len(rotation) != 4:
                raise RuntimeError(f"Invalid rotation for {joint_name}: expected rotation_wxyz [w, x, y, z].")

            translation = key.get("translation_xyz")

            if translation is not None and (not isinstance(translation, list) or len(translation) != 3):
                raise RuntimeError(f"Invalid translation for {joint_name}: expected translation_xyz [x, y, z].")

            cleaned_keys.append({
                "frame": int(key["frame"]),
                "time": float(key.get("time", 0.0)),
                "rotation_wxyz": [
                    float(rotation[0]),
                    float(rotation[1]),
                    float(rotation[2]),
                    float(rotation[3]),
                ],
                "translation_xyz": [
                    float(translation[0]),
                    float(translation[1]),
                    float(translation[2]),
                ] if translation is not None else None,
                "curve": str(key.get("curve", "linear")),
            })

        cleaned[joint_name] = sorted(cleaned_keys, key=lambda item: item["frame"])

    return {
        "schema": data["schema"],
        "fps": float(data.get("fps", 24.0)),
        "joints": cleaned,
    }


def build_times(solved):
    times = set()

    for keys in solved["joints"].values():
        for key in keys:
            times.add(int(key["frame"]))

    if not times:
        raise RuntimeError("Solved animation has no time samples.")

    return sorted(times)


def sample_joint_at_frame(keys, frame):
    for key in keys:
        if int(key["frame"]) == int(frame):
            return key

    previous = None

    for key in keys:
        if int(key["frame"]) <= int(frame):
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


def vec3f(x, y, z):
    return Gf.Vec3f(float(x), float(y), float(z))


def map_keyframes_to_target_joints(joint_paths, solved_joints):
    exact = {}
    lower = {}

    for index, joint_path in enumerate(joint_paths):
        leaf = leaf_name(joint_path)
        exact[leaf] = index
        lower[leaf.lower()] = index

    result = {}

    for canonical_name in solved_joints.keys():
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

    missing = sorted(set(solved_joints.keys()) - set(result.keys()))

    if missing:
        log(f"Warning: solved joints missing in target skeleton and ignored: {missing}")

    return result


def rest_local_transforms(skeleton, joint_paths):
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
    solved,
    clip_id,
    include_hips_translation,
):
    joint_paths = list(skeleton.GetJointsAttr().Get() or [])

    if not joint_paths:
        raise RuntimeError("Resolved reference skeleton path has empty joints attribute.")

    solved_joints = solved["joints"]
    joint_map = map_keyframes_to_target_joints(joint_paths, solved_joints)
    rest_translations, rest_rotations, rest_scales = rest_local_transforms(skeleton, joint_paths)
    times = build_times(solved)
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
        translations = list(rest_translations)
        rotations = list(rest_rotations)
        scales = list(rest_scales)

        for canonical_name, target_index in joint_map.items():
            key = sample_joint_at_frame(solved_joints[canonical_name], frame)
            delta_rotation = quatf_from_wxyz(key["rotation_wxyz"])

            # The ray solver produces local rotation deltas from the reference rest pose.
            # Keep target rest rotation intact and apply the solved delta on top.
            rotations[target_index] = rest_rotations[target_index] * delta_rotation

            if include_hips_translation and canonical_name == "Hips":
                translation_meters = key.get("translation_xyz")

                if translation_meters is not None:
                    root_delta_stage_units = vec3f(
                        translation_meters[0] / meters_per_unit,
                        translation_meters[1] / meters_per_unit,
                        translation_meters[2] / meters_per_unit,
                    )
                    translations[target_index] = translations[target_index] + root_delta_stage_units

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
    stage.SetFramesPerSecond(solved["fps"])
    stage.SetTimeCodesPerSecond(solved["fps"])

    log(f"Resolved skeleton from reference path: {skeleton.GetPrim().GetPath()}")
    log(f"Created animation: {anim.GetPrim().GetPath()}")
    log(f"Joint order count: {len(joint_paths)}")
    log(f"Matched joints: {len(joint_map)} / {len(solved_joints)}")
    log(f"Time range: {min(times)} - {max(times)} at {solved['fps']:.3f} fps")

    return anim


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


def write_readback_json_from_usdz(source_usdz, identity, output_json):
    if not output_json:
        return

    readback_dir = tempfile.mkdtemp(prefix="rotomotion_usdz_readback_")

    try:
        root_layer_path, root_member = unzip_usdz(source_usdz, readback_dir)
        stage = Usd.Stage.Open(root_layer_path)

        if stage is None:
            raise RuntimeError(f"Could not open exported USDZ for readback: {source_usdz}")

        skeleton = find_session_skeleton_for_readback(stage, identity)
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
            "rootLayerPathInsideUSDZ": root_member,
            "sessionSkeletonPath": identity.get("skeletonPath"),
            "sessionJointPaths": identity.get("jointPaths", []),
            "sessionJointLeafNames": identity.get("jointLeafNames", []),
            "stageFPS": float(stage.GetFramesPerSecond()),
            "stageStartTimeCode": float(stage.GetStartTimeCode()),
            "stageEndTimeCode": float(stage.GetEndTimeCode()),
            "metersPerUnit": float(UsdGeom.GetStageMetersPerUnit(stage) or 1.0),
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
    log(f"session_skeleton_identity = {args.session_skeleton_identity}")
    log(f"solved_json = {args.solved_json}")
    log(f"output_usdz = {args.output_usdz}")

    root_layer_path, root_member = unzip_usdz(args.target_usdz, unpack_dir)
    stage = Usd.Stage.Open(root_layer_path)

    if stage is None:
        raise RuntimeError(f"Could not open USD stage: {root_layer_path}")

    identity = load_session_skeleton_identity(args.session_skeleton_identity)

    skeleton = get_session_skeleton(
        stage=stage,
        identity=identity,
        preflight_json=args.preflight_json,
        target_usdz=args.target_usdz,
        root_layer_path=root_layer_path,
        root_member=root_member,
    )
    solved = load_solved_json(args.solved_json)

    create_animation(
        stage=stage,
        skeleton=skeleton,
        solved=solved,
        clip_id=args.clip_id,
        include_hips_translation=args.include_hips_translation,
    )

    save_stage_as_usdc(stage, out_usdc)
    asset_names = collect_non_usd_assets(root_layer_path)
    package_usdz(out_usdc, args.output_usdz, asset_names)

    try:
        write_readback_json_from_usdz(
            args.output_usdz,
            identity,
            args.readback_json,
        )
    except Exception as readback_error:
        write_readback_error_json(args.readback_json, args.output_usdz, readback_error)

    shutil.rmtree(unpack_dir, ignore_errors=True)
    log("DONE")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[rotomotion_existing_skeleton_export] ERROR: {error}", file=sys.stderr)
        sys.exit(1)
"""#
}
