// AI movement adapters for the WIP behavior tree port.
// A basic pathfinding walker on top of vg's get_path_to() with a per-controller
// path cache. The full tgstation movement/cell-tracker port is still pending.

/datum/ai_movement
	/// controller -> list of turfs to walk through.
	var/list/paths = list()

/// Starts (or replaces) a path towards target. Returns FALSE if no path was found.
/datum/ai_movement/proc/start_moving_towards(datum/ai_controller/controller, atom/target, max_distance = 30)
	return FALSE

/// Returns TRUE when the caller should replace the stored path for this target.
/datum/ai_movement/proc/needs_repath(datum/ai_controller/controller, atom/target)
	return !has_path(controller)

/// Advances one step. Returns TRUE if the pawn moved.
/datum/ai_movement/proc/process(datum/ai_controller/controller)
	return FALSE

/// Stops moving and drops the stored path.
/datum/ai_movement/proc/stop_moving_towards(datum/ai_controller/controller)
	paths -= controller

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
	/// Safety cap on steps spent in one planning tick.
	var/max_steps_per_tick = 20
	/// controller -> movement time (deciseconds) accumulated but not yet spent on
	/// a step. The planning tick is 1 s, so a mob whose legacy walk moved every
	/// 0.2 s needs several steps per tick to keep its speed.
	var/list/step_credit = list()
	/// controller -> target of an in-flight async path request.
	var/list/pending_paths = list()
	/// controller -> target the cached path was built for.
	var/list/path_targets = list()
	/// controller -> steps consumed from the cached path.
	var/list/path_steps = list()

/datum/ai_movement/basic/Destroy()
	path_targets = null
	path_steps = null
	step_credit = null
	pending_paths = null
	return ..()

/// Delay between steps in deciseconds. move_to_delay is in world ticks, exactly
/// like the Lag walk_to()/Goto() used before the port, so the adapter has to
/// scale it by world.tick_lag or every migrated mob moves far slower.
/datum/ai_movement/basic/proc/get_step_interval(datum/ai_controller/controller)
	var/mob/living/pawn = controller.pawn
	var/lag = 5
	if(istype(pawn, /mob/living/simple_animal/hostile))
		var/mob/living/simple_animal/hostile/hostile_pawn = pawn
		if(hostile_pawn.move_to_delay > 0)
			lag = hostile_pawn.move_to_delay
	return max(1, lag * world.tick_lag)

/datum/ai_movement/basic/stop_moving_towards(datum/ai_controller/controller)
	path_targets -= controller
	path_steps -= controller
	step_credit -= controller
	pending_paths -= controller
	return ..()

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
			return FALSE
		paths[controller] = list(fallback_step)
		path_targets[controller] = target
		path_steps[controller] = 0
		return TRUE

	paths[controller] = path
	path_targets[controller] = target
	path_steps[controller] = 0
	return TRUE

/datum/ai_movement/basic/process(datum/ai_controller/controller)
	var/mob/living/pawn = controller.pawn
	var/list/path = paths[controller]
	if(!pawn || QDELETED(pawn) || !path || !length(path))
		paths -= controller
		step_credit -= controller
		return FALSE

	// Accumulate real time (the planner can be delayed under load) and spend it
	// on steps at the legacy rate.
	var/seconds = controller.seconds_per_tick
	if(!seconds || seconds <= 0)
		seconds = 1
	step_credit[controller] += seconds * 10

	var/interval = get_step_interval(controller)
	var/steps = 0
	var/moved = FALSE
	while(step_credit[controller] >= interval && steps < max_steps_per_tick)
		var/turf/next_step = path[1]
		path.Cut(1, 2)
		step_credit[controller] -= interval
		steps++
		if(!next_step || !pawn.Move(next_step))
			paths -= controller
			step_credit -= controller
			return moved
		moved = TRUE
		path_steps[controller]++
		if(!length(path))
			break
	return moved
