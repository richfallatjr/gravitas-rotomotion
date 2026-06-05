enum RotoMotionUSDZOpacityPythonScript {
    static let contents = #"""
#!/usr/bin/env python3

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

from pxr import Usd, UsdShade, Sdf


def log(msg):
    print(f"[make_usdz_transparent] {msg}")


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--source-usdz", required=True)
    p.add_argument("--output-usdz", required=True)
    p.add_argument("--opacity", type=float, default=0.5)
    return p.parse_args()


def unzip_usdz(source_usdz, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)

    with zipfile.ZipFile(source_usdz, "r") as z:
        names = z.namelist()
        usd_names = [
            n for n in names
            if n.lower().endswith((".usd", ".usda", ".usdc"))
        ]

        if not usd_names:
            raise RuntimeError("No USD file found inside USDZ.")

        root_member = usd_names[0]
        z.extractall(dst_dir)

    root_layer = os.path.join(dst_dir, root_member)
    log(f"root layer: {root_layer}")
    return root_layer


def set_input(shader, name, type_name, value):
    inp = shader.GetInput(name)
    if not inp:
        inp = shader.CreateInput(name, type_name)
    inp.Set(value)


def make_materials_transparent(stage, opacity):
    material_count = 0
    shader_count = 0
    mesh_count = 0

    for prim in stage.Traverse():
        if prim.GetTypeName() == "Mesh":
            mesh_count += 1

            attr = prim.CreateAttribute(
                "primvars:displayOpacity",
                Sdf.ValueTypeNames.FloatArray
            )
            attr.Set([float(opacity)])

        if prim.IsA(UsdShade.Material):
            material_count += 1

        shader = UsdShade.Shader(prim)
        if shader:
            shader_id = shader.GetIdAttr().Get()

            if shader_id == "UsdPreviewSurface" or prim.GetName().lower().find("preview") >= 0:
                shader_count += 1

                set_input(shader, "opacity", Sdf.ValueTypeNames.Float, float(opacity))
                set_input(shader, "opacityThreshold", Sdf.ValueTypeNames.Float, 0.0)

    log(f"mesh_count={mesh_count}")
    log(f"material_count={material_count}")
    log(f"preview_surface_shader_count={shader_count}")

    if mesh_count == 0:
        log("WARNING: no Mesh prims found.")

    if shader_count == 0:
        log("WARNING: no UsdPreviewSurface shaders found. displayOpacity fallback was still authored on Mesh prims.")


def collect_package_assets(root_layer_path):
    root_dir = os.path.dirname(root_layer_path)
    root_name = os.path.basename(root_layer_path)
    assets = []

    for current_root, _, files in os.walk(root_dir):
        for filename in files:
            path = os.path.join(current_root, filename)
            rel = os.path.relpath(path, root_dir)

            if rel == root_name:
                continue

            assets.append(rel)

    return sorted(assets)


def package_usdz(root_layer_path, output_usdz):
    usdzip = shutil.which("usdzip")
    if usdzip is None:
        raise RuntimeError("usdzip is missing.")

    if os.path.exists(output_usdz):
        os.remove(output_usdz)

    root_dir = os.path.dirname(root_layer_path)
    root_name = os.path.basename(root_layer_path)
    asset_names = collect_package_assets(root_layer_path)

    cmd = [usdzip, output_usdz, "-r", root_name] + asset_names
    log("Running: " + " ".join(cmd))

    r = subprocess.run(
        cmd,
        cwd=root_dir,
        capture_output=True,
        text=True
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"usdzip failed\nSTDOUT:\n{r.stdout}\nSTDERR:\n{r.stderr}"
        )


def main():
    args = parse_args()

    work = tempfile.mkdtemp(prefix="rotomotion_opacity_usdz_")
    root_layer = unzip_usdz(args.source_usdz, work)

    stage = Usd.Stage.Open(root_layer)
    if stage is None:
        raise RuntimeError("Could not open USD stage.")

    make_materials_transparent(stage, args.opacity)

    stage.GetRootLayer().Save()

    package_usdz(root_layer, args.output_usdz)

    log(f"DONE output={args.output_usdz}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[make_usdz_transparent] ERROR: {e}", file=sys.stderr)
        sys.exit(1)
"""#
}
