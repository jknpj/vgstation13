// Ticks AI controllers (and their behavior trees).
// This is the vg subsystem adapter for the WIP tgstation behavior tree port;
// see code/datums/ai/README.md.
//
// There are two subsystems: SSai_controllers for AI_STATUS_ON (full rate) and
// SSai_controllers_low for AI_STATUS_ON_LOW (half rate). Controllers move
// between them through set_ai_status(), and each subsystem keeps its controllers
// in per-z buckets.

var/datum/subsystem/ai_controllers/SSai_controllers
var/datum/subsystem/ai_controllers/low/SSai_controllers_low
/// Controllers created before the subsystems exist (the map loads first); the
/// subsystems adopt them by status when they start.
var/list/ai_controllers_pending = list()

/// How close a client must be for a pawn floating in space to keep planning.
#define AI_NEARBY_CLIENT_RANGE 12

/datum/subsystem/ai_controllers
	name = "AI Controllers"
	wait = SS_WAIT_BOTS
	flags = SS_NO_INIT | SS_KEEP_TIMING
	priority = SS_PRIORITY_MOB

	/// Controllers being processed this fire; kept across a paused fire.
	var/list/currentrun
	/// Controllers grouped by z level. Keys are strings because a map index of
	/// 0 is out of bounds for DM lists (pawnless controllers land in "0").
	var/list/ai_controllers_by_z = list()
	/// CPU cost (ms) of the last completed pass.
	var/pass_cost = 0
	/// Rolling average of the pass cost (ms).
	var/average_pass_cost = 0
	/// Most expensive controller of the last pass, as "name Xms".
	var/worst_controller = null
	/// CPU cost (ms) of the most expensive controller of the last pass.
	var/worst_cost = 0

/datum/subsystem/ai_controllers/New()
	NEW_SS_GLOBAL(SSai_controllers)
	for(var/datum/ai_controller/controller in ai_controllers_pending.Copy())
		if(controller.ai_status != AI_STATUS_ON)
			continue
		index_controller(controller)
		ai_controllers_pending -= controller

/datum/subsystem/ai_controllers/stat_entry(msg)
	if(msg)
		return ..()
	var/total = 0
	for(var/key in ai_controllers_by_z)
		total += length(ai_controllers_by_z[key])
	msg = "AI:[total]|Cost:[round(pass_cost, 0.1)]ms|Avg:[round(average_pass_cost, 0.1)]ms"
	if(worst_controller)
		msg += "|Worst:[worst_controller]"
	..(msg)

/// Pawns floating in space only need to think while a client can see them.
/// Station and away-mission areas always tick, and the z gate in fire() already
/// skips bare z levels, so this only trims the empty parts of a watched z.
/datum/subsystem/ai_controllers/proc/is_controller_watched(datum/ai_controller/controller)
	var/mob/living/pawn = controller.pawn
	if(!pawn || QDELETED(pawn))
		return TRUE
	var/turf/pawn_turf = get_turf(pawn)
	if(!pawn_turf)
		return FALSE
	// The base /area is space; every station/ruin area is a subtype.
	if(get_area(pawn_turf).type != /area)
		return TRUE
	for(var/client/C in clients)
		var/mob/client_mob = C.mob
		if(client_mob && client_mob.z == pawn.z && get_dist(client_mob, pawn) <= AI_NEARBY_CLIENT_RANGE)
			return TRUE
	return FALSE

/// Adds a controller to the bucket for its pawn's z level, removing it from any
/// previous bucket first.
/datum/subsystem/ai_controllers/proc/index_controller(datum/ai_controller/controller)
	if(!controller)
		return
	unindex_controller(controller)

	var/z = 0
	var/mob/living/pawn = controller.pawn
	if(pawn && !QDELETED(pawn))
		z = pawn.z
	if(!isnum(z))
		z = 0

	var/key = "[z]"
	if(!(key in ai_controllers_by_z))
		ai_controllers_by_z[key] = list()
	// `ai_controllers_by_z[key] += controller` is not list-append sugar; use a
	// local list variable so += appends instead of trying list + atom.
	var/list/bucket = ai_controllers_by_z[key]
	bucket += controller
	controller.ai_indexed_z = z

/// Removes a controller from its z bucket.
/datum/subsystem/ai_controllers/proc/unindex_controller(datum/ai_controller/controller)
	if(!controller || isnull(controller.ai_indexed_z))
		return
	var/key = "[controller.ai_indexed_z]"
	if(key in ai_controllers_by_z)
		var/list/bucket = ai_controllers_by_z[key]
		bucket -= controller
		if(!length(bucket))
			ai_controllers_by_z -= key
	controller.ai_indexed_z = null

/// Moves controllers whose pawn changed z since they were indexed.
/datum/subsystem/ai_controllers/proc/sync_z_buckets()
	for(var/key in ai_controllers_by_z.Copy())
		var/z = text2num(key)
		var/list/bucket = ai_controllers_by_z[key]
		for(var/datum/ai_controller/controller in bucket.Copy())
			if(QDELETED(controller))
				bucket -= controller
				continue
			var/current_z = 0
			if(controller.pawn && !QDELETED(controller.pawn))
				current_z = controller.pawn.z
			if(current_z != z)
				index_controller(controller)
		if((key in ai_controllers_by_z) && !length(ai_controllers_by_z[key]))
			ai_controllers_by_z -= key

/// Returns the z levels that currently have a client on them. Controllers on
/// unobserved z levels are skipped: nobody can see them act.
/datum/subsystem/ai_controllers/proc/get_active_z_levels()
	var/list/active = list()
	for(var/client/C in clients)
		var/mob/mob = C.mob
		if(!mob)
			continue
		var/z = mob.z
		// Lobby/new-player mobs and detached holders can report z = 0; using a
		// numeric list index for that would runtime, and an out-of-range z
		// (admin-spawned holder, dynamic map) must not break the whole fire.
		if(!isnum(z) || z < 1 || z > world.maxz)
			continue
		active["[z]"] = TRUE
	return active

/datum/subsystem/ai_controllers/fire(resumed = FALSE)
	if(!resumed)
		sync_z_buckets()
		currentrun = list()
		pass_cost = 0
		worst_controller = null
		worst_cost = 0
		var/list/active = get_active_z_levels()
		if(!islist(active))
			active = list()
		for(var/key in ai_controllers_by_z)
			var/z = text2num(key)
			if(z != 0 && !active[key])
				continue
			currentrun += ai_controllers_by_z[key]
	tick_ai_controllers(currentrun, wait / 10)
	if(!length(currentrun))
		average_pass_cost = MC_AVERAGE(average_pass_cost, pass_cost)

/// Shared tick loop; mutates currentrun so a paused fire can resume in place.
/datum/subsystem/ai_controllers/proc/tick_ai_controllers(list/currentrun, seconds_per_tick)
	while(currentrun.len)
		var/datum/ai_controller/controller = currentrun[currentrun.len]
		currentrun.len--

		if(!controller || controller.gcDestroyed || controller.ai_status == AI_STATUS_OFF)
			continue
		if(!is_controller_watched(controller))
			continue

		// Real time since this controller last ran: a pass can span several ticks
		// under load, and movement/time accumulators must stay time-correct.
		var/controller_seconds = seconds_per_tick
		if(controller.last_bt_tick)
			controller_seconds = max(0.1, (world.time - controller.last_bt_tick) / 10)
		controller.last_bt_tick = world.time

		var/tick_usage_before = world.tick_usage
		controller.SelectBehaviors(controller_seconds)
		var/controller_cost = TICK_DELTA_TO_MS(world.tick_usage - tick_usage_before)
		if(controller_cost > 0)
			pass_cost += controller_cost
			if(controller_cost > worst_cost)
				worst_cost = controller_cost
				worst_controller = "[controller.pawn || controller] [round(controller_cost, 0.01)]ms"
		if(MC_TICK_CHECK)
			return

/datum/subsystem/ai_controllers/low
	name = "AI Controllers (low)"
	wait = SS_WAIT_BOTS * 2

/datum/subsystem/ai_controllers/low/New()
	NEW_SS_GLOBAL(SSai_controllers_low)
	for(var/datum/ai_controller/controller in ai_controllers_pending.Copy())
		if(controller.ai_status != AI_STATUS_ON_LOW)
			continue
		index_controller(controller)
		ai_controllers_pending -= controller
