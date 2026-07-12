"""Run the complete extraction pipeline from a clean checkout.

Usage:  python -m tools.iw2.extract_all
"""

from . import assemble_avatar, export_gltf, extract_sims, lws, map_decoder, textures

print("=== sims ===")
extract_sims.main()
print("=== star maps ===")
map_decoder.main()
print("=== scenes ===")
lws.main()
print("=== textures ===")
textures.main()
print("=== meshes ===")
export_gltf.main()
print("=== avatars ===")
import sys

sys.argv = [sys.argv[0], "--all"]
assemble_avatar.main()
