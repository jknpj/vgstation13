/datum/unit_test/shuttle_console_destroy/start()
	var/turf/T = locate(1, 1, 1)
	var/datum/shuttle/S = new
	var/obj/machinery/computer/shuttle_control/C = new(T)
	C.link_to(S)

	if(!(C in S.control_consoles))
		fail("The console was not linked to the shuttle.")

	qdel(C)

	if(C in S.control_consoles)
		fail("A destroyed console stayed in the shuttle's control_consoles.")

	qdel(S)
