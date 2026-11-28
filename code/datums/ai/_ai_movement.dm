// AI movement adapters for the WIP behavior tree port.
// A basic pathfinding walker on top of vg's get_path_to() with a per-controller
// path cache. The full tgstation movement/cell-tracker port is still pending.
//
// Movement is stepped by SSai_movement (one tile per world tick, at the legacy
// move_to_delay rate) instead of by the 1 s planning tick. Decisions are slow on
// purpose; moving a whole second of steps inside one plan tick made pawns
// visibly teleport.

/datum/ai_movement
	/// controller -> list of turfs to walk through.
	var/list/paths = list()

/// Starts (or replaces) a path towards target. Returns FALSE if no path was found.
/datum/ai_movement/proc/start_moving_towards(datum/ai_controller/controller, atom/target, max_distance = 30)
	return FALSE

/// Returns TRUE when the caller should replace the stored path for this target.
/datum/ai_movement/proc/needs_repath(datum/ai_controller/controller, atom/target)
	return !has_path(controller)

/// Advances at most one step if enough world time elapsed. Returns TRUE if the
/// pawn moved. Called by SSai_movement every world tick; leaves never call it.
/datum/ai_movement/proc/process(datum/ai_controller/controller)
	return FALSE

/// Stops moving and drops the stored path.
/datum/ai_movement/proc/stop_moving_towards(datum/ai_controller/controller)
	paths -= controller

/// TRUE when the last step attempt failed. Consuming it clears the flag so the
/// plan tick can retry after the tree tried another branch (smashing, fleeing).
/datum/ai_movement/proc/take_blocked(datum/ai_controller/controller)
	return FALSE

/// Returns TRUE while there are queued steps for this controller.
/datum/ai_movement/proc/has_path(datum/ai_controller/controller)
	var/list/path = paths[controller]
	return !!path && length(path) > 0

/datum/ai_movement/Destroy()
	paths = null
	return ..()

/datum/ai_movement/basic
	/// Recompute a path when this many steps have been consumed and the target moved.
	var/repath_after = 8
	/// controller -> movement time (deciseconds) accumulated but not yet spent on
	/// a step. The planning tick is 1 s, so a mob whose legacy walk moved every
	/// 0.2 s needs several steps per tick to keep its speed.
	var/list/next_step_time = list()
	/// controller -> TRUE when the last step could not be taken.
	var/list/step_blocked = list()
	/// controller -> target of an in-flight async path request.
	var/list/pending_paths = list()
	/// controller -> target the cached path was built for.
	var/list/path_targets = list()
	/// controller -> steps consumed from the cached path.
	var/list/path_steps = list()

/datum/ai_movement/basic/Destroy()
	path_targets = null
	path_steps = null
	next_step_time = null
	step_blocked = null
	pending_paths = null
	return ..()

/// Delay between steps in deciseconds. move_to_delay is in world ticks, exactly
/// like the Lag walk_to()/Goto() used before the port, so the adapter scales the
/// tick count by world.tick_lag. The floor is one world tick: a faster step than
/// the ticker can deliver would just bunch up again.
/datum/ai_movement/basic/proc/get_step_interval(datum/ai_controller/controller)
	var/mob/living/pawn = controller.pawn
	var/lag = 5
	if(istype(pawn, /mob/living/simple_animal/hostile))
		var/mob/living/simple_animal/hostile/hostile_pawn = pawn
		if(hostile_pawn.move_to_delay > 0)
			lag = hostile_pawn.move_to_delay
	return max(1, lag) * world.tick_lag

/datum/ai_movement/basic/stop_moving_towards(datum/ai_controller/controller)
	path_targets -= controller
	path_steps -= controller
	next_step_time -= controller
	step_blocked -= controller
	pending_paths -= controller
	ai_movement_active -= controller
	return ..()

/// True when the last step could not be taken; consuming it lets the tree fall
/// through to a branch that can clear the way instead of retrying forever.
/datum/ai_movement/basic/take_blocked(datum/ai_controller/controller)
	var/blocked = step_blocked[controller]
	step_blocked -= controller
	return !!blocked

/// Queues a real path on the pathfinder subsystem while it is saturated. The
/// greedy fallback keeps the pawn moving; on_async_path() swaps in the real path
/// if the pawn is still close enough to its start.
/datum/ai_movement/basic/proc/queue_async_path(datum/ai_controller/controller, atom/target, max_distance)
	if(pending_paths[controller] == target)
		return
	pending_paths[controller] = target
	var/datum/path_request/request = new
	request.caller = controller.pawn
	request.target = target
	request.max_distance = max_distance
	request.diagonally = FALSE
	request.cardinalize = TRUE
	request.on_finish = new /callback(src, nameof(src::on_async_path()), controller, target)
	SSpathfinder.queue_path(request)

/// Callback for a finished async path request: adopt the path when the pawn is
/// still chasing the same target and can reach its first step.
/datum/ai_movement/basic/proc/on_async_path(datum/ai_controller/controller, atom/target, list/path)
	pending_paths -= controller
	if(!controller || QDELETED(controller) || !controller.pawn)
		return
	if(!path || !length(path))
		return
	if(path_targets[controller] != target)
		return
	var/turf/first_step = path[1]
	if(!first_step || get_dist(controller.pawn, first_step) > 1)
		return // the greedy fallback moved us past the request's start
	paths[controller] = path
	path_steps[controller] = 0
	path_targets[controller] = target
	ai_movement_active |= controller

/datum/ai_movement/basic/needs_repath(datum/ai_controller/controller, atom/target)
	if(!has_path(controller))
		return TRUE
	// A different target always invalidates the cached path.
	if(!target || path_targets[controller] != target)
		return TRUE
	return path_steps[controller] >= repath_after

/datum/ai_movement/basic/start_moving_towards(datum/ai_controller/controller, atom/target, max_distance = 30)
	var/mob/living/pawn = controller.pawn
	if(!pawn || !target || QDELETED(target) || QDELETED(pawn))
		return FALSE
	if(!get_turf(pawn) || !get_turf(target))
		return FALSE

	// Pathfinding can be unavailable while the pathfinder subsystem is still
	// starting; fall back to one greedy step instead of runtiming.
	var/list/path
	var/datum/flowcache/slots = SSpathfinder ? SSpathfinder.mobs : null
	// get_path_to() stoplag()s until a pathfinder slot frees up, and a planning
	// tick must never sleep. If the cache is full, queue the real path on the
	// pathfinder subsystem and take the greedy fallback below meanwhile.
	if(slots && slots.run < slots.lcount)
		path = get_path_to(
			pawn,
			target,
			max_distance = max_distance,
			mintargetdist = 0,
			simulated_only = TRUE,
			skip_first = TRUE,
			diagonally = FALSE,
			cardinalize = TRUE,
		)
	else if(SSpathfinder)
		queue_async_path(controller, target, max_distance)

	if(!path || !length(path))
		var/turf/fallback_step = get_step_towards(pawn, target)
		if(!fallback_step)
			paths -= controller
			ai_movement_active -= controller
			return FALSE
		paths[controller] = list(fallback_step)
		path_targets[controller] = target
		path_steps[controller] = 0
		ai_movement_active |= controller
		return TRUE

	paths[controller] = path
	path_targets[controller] = target
	path_steps[controller] = 0
	ai_movement_active |= controller
	return TRUE

/datum/ai_movement/basic/process(datum/ai_controller/controller)
	var/mob/living/pawn = controller.pawn
	var/list/path = paths[controller]
	if(!pawn || QDELETED(pawn) || !path || !length(path))
		paths -= controller
		ai_movement_active -= controller
		return FALSE

	// One step per due interval: the ticker fires every world tick, so this keeps
	// the legacy walk rate without moving a second of steps in a single tick.
	if(world.time < (next_step_time[controller] || 0))
		return FALSE
	// Small epsilon so a tick-quantised world.time cannot land one ulp below the
	// scheduled time and delay the step by a whole extra tick.
	next_step_time[controller] = world.time + get_step_interval(controller) - 0.001

	var/turf/next_step = path[1]
	path.Cut(1, 2)
	path_steps[controller]++
	if(!next_step || !pawn.Move(next_step))
		// The route is stale or blocked: drop it. The plan tick rebuilds it, and
		// take_blocked() lets the tree try a branch that can clear the way.
		paths -= controller
		ai_movement_active -= controller
		step_blocked[controller] = TRUE
		return FALSE

	if(!length(path))
		// Path spent. The plan tick asks for a new one if the chase is still on.
		ai_movement_active -= controller
	return TRUE
