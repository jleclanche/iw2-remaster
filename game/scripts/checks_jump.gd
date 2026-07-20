extends "checks_base.gd"
# --jumpcheck: capsule jump initiate-to-arrival.
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

# --- capsule jump -------------------------------------------------------------

func _jumpcheck(_delta: float) -> void:
	# validate a capsule jump: start at Alexander L-Point -> route to Coyote
	match demo_phase:
		0:
			if demo_t > 1.0:
				print("JUMPCHECK: from ", m.system_stem, ", routes: ",
					m.routes_text())
				m._try_jump()
				if m.jump_state == 0:
					print("JUMPCHECK: FAILED to initiate")
					get_tree().quit(1)
				demo_phase = 1
		1:
			if m.jump_state == 0:
				print("JUMPCHECK: now in ", m.system_stem,
					" (", m.system_name, ")")
				demo_phase = 2
				demo_t = 0.0
		2:
			if demo_t > 1.5:
				if not m._headless():
					_shot("jump_arrival")
				var ok: bool = m.system_stem != m.START_SYSTEM
				print("JUMPCHECK: ", "PASS" if ok else "FAIL",
					" — arrived in ", m.system_name,
					", contacts=", m.contact_list().size())
				get_tree().quit(0 if ok else 1)
	if demo_t > 60.0:
		print("JUMPCHECK: TIMEOUT in state ", m.jump_state)
		get_tree().quit(1)

