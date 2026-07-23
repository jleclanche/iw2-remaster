class_name CheckRunner
extends "checks_mech.gd"
# The automated test harness: --demo / --mechcheck / --jumpcheck /
# --uicheck / --campcheck / --motioncheck cmdline modes. Owns all the
# phase machines that used to live in main.gd; `m` is the game root.
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

func step(delta: float) -> void:
	demo_t += delta
	if m.fireprobe:
		_fireprobe(delta)
	elif m.contactcheck:
		_contactcheck(delta)
	elif m.sunshot:
		_sunshot(delta)
	elif m.sungallery:
		_sungallery(delta)
	elif m.srgbprobe:
		_srgbprobe(delta)
	elif m.muzzleshot:
		_muzzleshot(delta)
	elif m.commshot:
		_commshot(delta)
	elif m.newgametest:
		_newgametest(delta)
	elif m.basecheck:
		_basecheck(delta)
	elif m.newgamecheck:
		_newgamecheck(delta)
	elif m.campcheck:
		_campcheck(delta)
	elif m.uicheck:
		_uicheck(delta)
	elif m.jumpcheck:
		_jumpcheck(delta)
	elif m.mechcheck or m.mechslow:
		_mechcheck(delta)
		if m.ap_mode > 0 and m.docked_at == "":
			m._autopilot_process(delta)
	elif m.motioncheck:
		_motioncheck(delta)
	elif m.geogcheck:
		_geogcheck(delta)
	else:
		_demo(delta)

