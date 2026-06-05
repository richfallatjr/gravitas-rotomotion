# RotoMotion USDZ Export Diagnosis

Date: 2026-06-04

Compared files:

- `Meshy_AI_Animation_Walking.usdz` = working/reference package
- `rotomotion_inside_out_01_animated_target.usdz` = broken RotoMotion export
- Export work folder used for readback:
  `/Users/richardfallat/Projects/Gravitas/RotoMotion/rich-fallat/anim-export/rotomotion_inside_out_01_animated_usdz_work`

## Executive Summary

The broken export is not failing because the mesh, materials, weights, or original skeleton disappeared. Those are preserved.

The broken export fails because the active RotoMotion `SkelAnimation` is semantically wrong:

1. The active animation is authored/bound differently from the working Meshy animation.
2. The active RotoMotion animation contains large local-rotation discontinuities before Blender ever reads it.
3. The current rotation builder derives joint rotations from one bone direction only, which loses twist and allows alternate equivalent local rotations to flip frame-to-frame.
4. The exporter composes those unstable "direction delta" rotations with the target rest rotations, so Blender receives a valid USD animation that is not a stable skinned local pose animation.

This is a transform/retargeting bug, not a USDZ packaging bug.

## Confirmed USDZ Structure Differences

### Working Meshy package

Header:

```text
startTimeCode = 1
endTimeCode = 32
timeCodesPerSecond = 30
metersPerUnit = 1
upAxis = "Z"
```

Skeleton:

```text
/root/Armature/Armature
```

Active animation binding:

```text
rel skel:animationSource = </root/Armature/Armature/Anim>
```

Animation prim:

```text
/root/Armature/Armature/Anim
```

Important: Meshy authors the active `SkelAnimation` as a child of the existing `Skeleton`.

### Broken RotoMotion package

Header:

```text
startTimeCode = 0
endTimeCode = 369
framesPerSecond = 29.97002997002997
timeCodesPerSecond = 29.97002997002997
metersPerUnit = 1
upAxis = "Z"
```

Skeleton:

```text
/root/Armature/Armature
```

Active animation binding:

```text
rel skel:animationSource = </root/Armature/RotoMotionAnim_rotomotion_inside_out_01>
```

Animation prim:

```text
/root/Armature/RotoMotionAnim_rotomotion_inside_out_01
```

Problem: RotoMotion authored the active animation as a sibling of the skeleton under `/root/Armature`, while the known-good Meshy package authors it under `/root/Armature/Armature`.

The original Meshy `Anim` is still present in the broken file and still looks good, but it is no longer the active animation source.

## Package Contents

Both packages contain the same texture payload sizes:

```text
Meshy_AI_Animation_Walking.usdz
  output.usdc                     16,300,483 bytes
  textures/color_121212.hdr              109 bytes
  textures/texture_0.png           29,322,543 bytes

rotomotion_inside_out_01_animated_target.usdz
  rotomotion_inside_out_01_animated_target.usdc  16,566,800 bytes
  textures/texture_0.png                         29,322,543 bytes
  textures/color_121212.hdr                             109 bytes
```

Conclusion: textures are not the difference causing the mangled animation. The broken package is large because it preserves the target package assets, and the USDC is only slightly larger due to the added 369-frame animation.

## Animation Jump Metrics

### Working Meshy `Anim`

Samples:

```text
rotations:    31 samples, frames 1-31
translations: 31 samples, frames 1-31
scales:       31 samples, frames 1-31
```

Worst local rotation jumps:

```text
LeftLeg:      20.6 degrees
RightLeg:     18.7 degrees
LeftToeBase:  12.6 degrees
LeftFoot:     11.7 degrees
RightFoot:    11.5 degrees
```

No joint exceeds 90 degrees between adjacent frames.

### Broken RotoMotion active animation

Samples:

```text
rotations:    369 samples, frames 0-368
translations: 369 samples, frames 0-368
scales:       369 samples, frames 0-368
```

Worst local rotation jumps:

```text
RightForeArm: 175.9 degrees, frame 117 -> 118
RightArm:     172.7 degrees, frame 286 -> 287
LeftForeArm:   84.3 degrees, frame 115 -> 116
LeftArm:       74.6 degrees, frame 296 -> 297
```

The export work folder confirms this is already present in the JSON sent to Python:

```text
export input jumps:
RightForeArm: 175.9 degrees
RightArm:     172.7 degrees
LeftForeArm:   84.3 degrees
LeftArm:       74.6 degrees

readback jumps:
RightForeArm: 175.9 degrees
RightArm:     172.7 degrees
LeftForeArm:   84.3 degrees
LeftArm:       74.6 degrees
```

Conclusion: Python/USDZ packaging is faithfully writing bad local rotation keys. The bad keys are generated before the USDZ is packaged.

## Position vs Rotation Pattern

The viewport can look acceptable because it draws solved joint positions and bones.

The export fails because skinned USDZ playback uses local rotations.

For the same problem joints:

```text
RightArm:
  max position jump: 0.6196 scene units
  max rotation jump: 172.7 degrees

RightForeArm:
  max position jump: 1.4022 scene units
  max rotation jump: 175.9 degrees

Hips:
  max position jump: 0.0500 scene units
  max rotation jump: 0.0 degrees
```

This means the point solve can remain plausible while the reconstructed local rotation suddenly chooses the opposite/twisted orientation.

## Current Code Pattern Causing This

`RotoSolvedPoseRotationBuilder` currently builds each local rotation like this:

```swift
let q = simd_quatf(
    from: restDirection,
    to: solvedDirection
)
```

That uses only a single direction vector:

```text
parent -> child
```

That is not enough information to define a full skeletal joint orientation. It loses twist around the bone axis. When the arm/forearm crosses an ambiguous pose, there are multiple valid rotations that point the child bone at the same solved position. The code can pick a different equivalent solution on the next frame, causing a 170-180 degree local rotation jump.

Then the USD exporter applies:

```python
rotations[target_index] = rest_rotations[target_index] * delta_rotation
```

So the exporter is applying an unstable direction-only delta onto the target rest transform. That creates a valid USD animation, but not a stable skinned local pose animation.

## Confirmed Non-Causes

These are not the primary failure:

```text
USDZ validity: both packages pass usdchecker.
Missing mesh: mesh package is preserved.
Missing texture/materials: texture payload is the same.
Missing skeleton: skeleton exists at /root/Armature/Armature.
Joint order mismatch: active animation uses the same 24 joint paths.
Huge root translation: active RotoMotion root translation span is small:
  x span 0.1642
  y span 0.0878
  z span 0.0000
```

The audit warning about Hips starting ~98 units from origin is the target skeleton's rest translation, not the primary mangling pattern.

## Robust Fix Required

### 1. Stop deriving export rotations from one vector

Do not export local rotations from:

```text
quat(from: rest parent-child direction, to: solved parent-child direction)
```

That is underdetermined.

Instead build a full per-joint orientation frame:

```text
primary axis   = parent -> child direction
secondary axis = pole/up/right/reference child direction
tertiary axis  = cross product
```

Examples:

```text
torso: use body basis up/right/forward
shoulders: use body right + body forward
upper arms: use elbow direction + body forward pole
forearms: use wrist direction + elbow/hand plane
legs: use knee/ankle direction + body forward pole
head: use neck->head plus headfront/head_end where available
```

Then compute stable world joint orientations from those frames and convert to parent-local rotations.

### 2. Carry orientation through the IK solve

The solver should output:

```text
jointPositions
jointWorldRotationsWXYZ
jointLocalRotationsWXYZ
```

It should not reconstruct local rotations afterward from positions only.

For every frame, choose the local rotation candidate with maximum dot product against the previous frame's local rotation:

```text
candidate = solve local rotation
if dot(candidate, previous) < 0: candidate = -candidate
choose/minimize angular delta from previous
```

This is not smoothing. It is continuity selection among valid orientation solutions.

### 3. Retarget against the target skeleton rest basis, not canonical fallback axes

The correct export transform should be based on the USD skeleton's actual `restTransforms`:

```text
source/reference rest local basis
solved source local basis
target rest local basis
```

Required mapping:

```text
sourceDelta = inverse(sourceRestLocalRotation) * solvedSourceLocalRotation
targetLocal = targetRestLocalRotation * sourceDelta
```

The exact multiplication order must be verified with a one-bone USD unit test because USD/Gf quaternion multiplication order can be easy to invert. The current blind `rest * delta` is not trustworthy until that test exists.

### 4. Fix USD animation placement

Author the new animation as a child of the existing skeleton:

```text
/root/Armature/Armature/RotoMotionAnim_<clip>
```

Not:

```text
/root/Armature/RotoMotionAnim_<clip>
```

Then bind:

```text
rel skel:animationSource = </root/Armature/Armature/RotoMotionAnim_<clip>>
```

This matches the working Meshy package structure.

### 5. Match Meshy frame convention unless there is a reason not to

Working Meshy animation starts at frame 1.

Broken RotoMotion animation starts at frame 0.

This is probably not the main mangling cause, but the exporter should use a consistent convention:

```text
USD frame = source frame + 1
startTimeCode = 1
endTimeCode = frameCount
```

### 6. Treat root translation separately

Do not mix SceneKit/video-card coordinates directly into USD skeleton local translation.

Root translation must be converted through an explicit coordinate-space mapping:

```text
RotoMotion scene basis -> reference skeleton local basis -> target USD skeleton basis
```

Until that mapping is proven, animated USDZ export should default to rotations-only or Hips translation off.

## Required Validation For The Real Fix

The exporter should reject or flag the output if any of these are true:

```text
active SkelAnimation is not under the resolved Skeleton prim
skel:animationSource does not point to that animation
joint order differs from skeleton.joints
any local rotation jumps > 45 degrees without a matching position jump
any quaternion sign continuity fails
source solve local rotations differ from USDZ readback local rotations
root translation is written without explicit basis conversion
```

For the dropped broken file, the audit should have failed hard on:

```text
RightArm local rotation jump: 172.7 degrees
RightForeArm local rotation jump: 175.9 degrees
active animation path outside skeleton
```

## Bottom Line

The real fix is not another exporter toggle and not a scale tweak.

The robust fix is:

```text
build stable full local joint orientations from body/limb frames,
retarget those orientations through USD skeleton rest transforms,
author the SkelAnimation under the existing Skeleton,
and fail export when readback contains impossible local rotation jumps.
```

Until local orientations are generated from full frames instead of one bone direction, the viewport can look good while the USDZ remains mangled.
