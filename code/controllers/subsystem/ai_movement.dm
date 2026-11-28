// Steps AI movement paths on the world tick.
//
// Decisions run once per second (SSai_controllers) but a legacy walk() moved one
// tile every move_to_delay world ticks. Spending a whole second of steps inside
// the planning tick made pawns teleport across the room, so movement lives in
// this ticker subsystem instead: at most one step per controller per world tick,
// at the adapter's get_step_interval() rate.

var/datum/subsystem/ai_movement/SSai_movement
/// Controllers with a live path in their movement adapter. Registered by
/// ai_movement.start_moving_towards() and cleared when the path ends.
var/list/ai_movement_active = list()

/datum/subsystem/ai_movement
	name = "AI Movement"
	wait = 1
	flags = SS_TICKER | SS_NO_INIT
	priority = SS_PRIORITY_BOTS
	/// Controllers being stepped this fire; kept across a paused fire.
	var/list/currentrun

/datum/subsystem/ai_movement/New()
	NEW_SS_GLOBAL(SSai_movement)

/datum/subsystem/ai_movement/stat_entry(msg)
	if(msg)
		return ..()
	..("Moving:[length(ai_movement_active)]")

/datum/subsystem/ai_movement/fire(resumed = FALSE)
	if(!resumed)
		currentrun = ai_movement_active.Copy()
	while(length(currentrun))
		var/datum/ai_controller/controller = currentrun[currentrun.len]
		currentrun.len--

		if(!controller || QDELETED(controller) || QDELETED(controller.pawn))
			ai_movement_active -= controller
			continue
		var/datum/ai_movement/movement = controller.ai_movement
		if(!movement)
			ai_movement_active -= controller
			continue

		movement.process(controller)
		if(MC_TICK_CHECK)
			return
