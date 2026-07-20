extends "checks_base.gd"
# --jumpcheck: capsule jump initiate-to-arrival.
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

# --- capsule jump -------------------------------------------------------------

var _jq_seen := false

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
			# camera 25 (#34): while the jump is queued the director's drop
			# camera holds a FIXED external viewpoint ahead of the run --
			# the eye must be parked away from the hull, not riding it
			if m.jump_state in [1, 2] and m._jq_set:
				var away: float = m.cam.global_position.distance_to(
						m.ship.global_position)
				if not _jq_seen and away < m.ship.radius:
					print("JUMPCHECK: FAIL — queue camera inside the hull ",
							"(%.0f m)" % away)
					get_tree().quit(1)
				_jq_seen = true
			if m.jump_state == 0:
				if not _jq_seen:
					print("JUMPCHECK: FAIL — camera 25 never engaged ",
							"during the queue")
					get_tree().quit(1)
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

