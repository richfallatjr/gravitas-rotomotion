enum RotoMotionUSDZInspectorPythonScript {
    static let contents = #"""
#!/usr/bin/env python3

import argparse
import json
import math
import os
import sys
import tempfile
import zipfile

from pxr import Usd, UsdGeom, UsdSkel, Gf


CANONICAL = [
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


ALIASES = {
    "neck": ["neck", "Neck"],
    "head_end": ["head_end", "HeadEnd", "Head_End"],
    "headfront": ["headfront", "HeadFront", "Head_Front"],
}


def log(message):
    print(f"[rotomotion_usdz_inspector] {message}")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-usdz", required=True)
    parser.add_argument("--output-json", required=True)
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


def leaf(path):
    text = str(path)

    if "/" in text:
        text = text.split("/")[-1]

    if ":" in text:
        text = text.split(":")[-1]

    return text


def parent_path(path):
    text = str(path).replace(":", "/")

    if "/" not in text:
        return None

    return "/".join(text.split("/")[:-1])


def find_skeleton(stage):
    skeletons = []

    for prim in stage.Traverse():
        if prim.IsA(UsdSkel.Skeleton):
            skeletons.append(UsdSkel.Skeleton(prim))

    if not skeletons:
        raise RuntimeError("No UsdSkel.Skeleton found.")

    if len(skeletons) > 1:
        log(f"Warning: found {len(skeletons)} skeletons; using first: {skeletons[0].GetPath()}")

    return skeletons[0]


def find_skel_root(skeleton):
    prim = skeleton.GetPrim()

    while prim and prim.IsValid():
        if prim.IsA(UsdSkel.Root):
            return str(prim.GetPath())

        prim = prim.GetParent()

    return None


def canonical_lookup(leaf_names):
    exact = {name: name for name in leaf_names}
    lower = {name.lower(): name for name in leaf_names}
    result = {}

    for canonical in CANONICAL:
        candidates = [canonical] + ALIASES.get(canonical, [])
        match = None

        for candidate in candidates:
            if candidate in exact:
                match = exact[candidate]
                break

            lowered = candidate.lower()
            if lowered in lower:
                match = lower[lowered]
                break

        if match is not None:
            result[canonical] = match

    return result


def local_translation(matrix):
    t = matrix.ExtractTranslation()
    return Gf.Vec3d(float(t[0]), float(t[1]), float(t[2]))


def vec_length(value):
    return math.sqrt(
        float(value[0]) * float(value[0]) +
        float(value[1]) * float(value[1]) +
        float(value[2]) * float(value[2])
    )


def compute_bone_lengths_meters(joint_paths, rest_transforms, meters_per_unit, canonical_to_leaf):
    by_leaf = {}

    for index, joint_path in enumerate(joint_paths):
        if index >= len(rest_transforms):
            continue

        by_leaf[leaf(joint_path)] = vec_length(local_translation(rest_transforms[index])) * meters_per_unit

    result = {}

    for canonical, actual_leaf in canonical_to_leaf.items():
        result[canonical] = float(by_leaf.get(actual_leaf, 0.0))

    return result


def compute_world_transforms(joint_paths, rest_transforms):
    world = {}

    for index, joint_path in enumerate(joint_paths):
        if index >= len(rest_transforms):
            continue

        path = str(joint_path).replace(":", "/")
        parent = parent_path(joint_path)
        local = rest_transforms[index]

        if parent and parent in world:
            world[path] = world[parent] * local
        else:
            world[path] = local

    return world


def estimate_height_meters(stage, joint_paths, rest_transforms, meters_per_unit, bone_lengths):
    world = compute_world_transforms(joint_paths, rest_transforms)
    up_axis = str(UsdGeom.GetStageUpAxis(stage) or "Y")
    axis_index = 2 if up_axis == "Z" else 1
    values = []

    for matrix in world.values():
        t = matrix.ExtractTranslation()
        values.append(float(t[axis_index]) * meters_per_unit)

    if values:
        height = max(values) - min(values)

        if math.isfinite(height) and height > 0.0001:
            return float(height)

    chain = 0.0

    for joint in ["LeftLeg", "LeftFoot", "Spine02", "Spine01", "Spine", "neck", "Head", "head_end"]:
        chain += float(bone_lengths.get(joint, 0.0))

    if chain > 0.0001:
        return float(chain)

    return None


def main():
    args = parse_args()
    work = tempfile.mkdtemp(prefix="rotomotion_usdz_inspect_")
    root_layer, root_member = unzip_usdz(args.source_usdz, work)

    stage = Usd.Stage.Open(root_layer)

    if stage is None:
        raise RuntimeError(f"Could not open USD stage: {root_layer}")

    skeleton = find_skeleton(stage)
    joint_paths = list(skeleton.GetJointsAttr().Get() or [])

    if not joint_paths:
        raise RuntimeError("Skeleton has no joints attribute.")

    leaf_names = [leaf(joint_path) for joint_path in joint_paths]
    canonical_to_leaf = canonical_lookup(leaf_names)
    matched = [joint for joint in CANONICAL if joint in canonical_to_leaf]
    missing = [joint for joint in CANONICAL if joint not in canonical_to_leaf]
    rest = list(skeleton.GetRestTransformsAttr().Get() or [])

    if len(rest) < len(joint_paths):
        raise RuntimeError("Skeleton restTransforms are missing or shorter than joints.")

    meters_per_unit = float(UsdGeom.GetStageMetersPerUnit(stage) or 1.0)
    bone_lengths = compute_bone_lengths_meters(
        joint_paths,
        rest,
        meters_per_unit,
        canonical_to_leaf,
    )

    profile = {
        "sourcePath": args.source_usdz,
        "rootLayerPathInsideUSDZ": root_member,
        "skeletonPath": str(skeleton.GetPrim().GetPath()),
        "skelRootPath": find_skel_root(skeleton),
        "jointPaths": [str(joint_path) for joint_path in joint_paths],
        "jointLeafNames": leaf_names,
        "canonicalMatchedJoints": matched,
        "missingCanonicalJoints": missing,
        "estimatedHeightMeters": estimate_height_meters(
            stage,
            joint_paths,
            rest,
            meters_per_unit,
            bone_lengths,
        ),
        "boneLengths": bone_lengths,
    }

    with open(args.output_json, "w") as handle:
        json.dump(profile, handle, indent=2, sort_keys=True)

    log("done")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[rotomotion_usdz_inspector] ERROR: {error}", file=sys.stderr)
        sys.exit(1)
"""#
}
