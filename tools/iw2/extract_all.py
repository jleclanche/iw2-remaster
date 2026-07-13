"""Run the complete extraction pipeline from a clean checkout.

Usage:  python -m tools.iw2.extract_all
"""

from . import (assemble_avatar, audio, classify_map, export_gltf,
               extract_sims, lwo, lws, map_decoder, sfx, textures)

print("=== sims ===")
extract_sims.main()
print("=== star maps ===")
map_decoder.main()
print("=== map classification ===")
classify_map.main()
print("=== collision hulls / lwo ===")
lwo.main()
print("=== audio ===")
audio.main()
print("=== scenes ===")
lws.main()
print("=== composite effects (sfx/*.lws) ===")
sfx.main()
print("=== textures ===")
textures.main()
print("=== fonts ===")
from . import fonts
fonts.main()
print("=== html (screen UI text, Latin-1 -> UTF-8) ===")
from . import html_text
html_text.main()
print("=== mission packages ===")
from . import campaign, pkg
pkg.main()
campaign.main()
print("=== meshes ===")
export_gltf.main()
print("=== avatars ===")
import sys

sys.argv = [sys.argv[0], "--all"]
assemble_avatar.main()
