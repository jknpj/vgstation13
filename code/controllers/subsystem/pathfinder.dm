var/datum/subsystem/pathfinder/SSpathfinder

/datum/subsystem/pathfinder
	name = "Pathfinder"
	init_order = SS_INIT_PATHFINDER
	/// Async path requests are drained here, one tick worth at a time.
	flags = SS_KEEP_TIMING
	wait = 1 SECONDS
	var/datum/flowcache/mobs
	var/static/space_type_cache
	/// Queued /datum/path_request entries, oldest first.
	var/list/requests = list()
	/// Requests finished in the last fire; for the stat entry.
	var/requests_processed = 0

/datum/subsystem/pathfinder/New()
	NEW_SS_GLOBAL(SSpathfinder)

/datum/subsystem/pathfinder/Initialize()
	space_type_cache = typesof(/turf/space) + typesof(/turf/simulated/open)
	generate_type_list_cache(space_type_cache)
	mobs = new(10)
	return ..()

/datum/subsystem/pathfinder/stat_entry(msg)
	if(msg)
		return ..()
	..("Path:[length(requests)]|Done:[requests_processed]")

/// Queues a path for the subsystem to compute when a slot is free. One request
/// per caller: a newer target replaces the older one.
/datum/subsystem/pathfinder/proc/queue_path(datum/path_request/request)
	if(!request || !request.caller || !request.target)
		return FALSE
	for(var/datum/path_request/old_request in requests)
		if(old_request.caller == request.caller)
			requests -= old_request
			break
	requests += request
	return TRUE

/datum/subsystem/pathfinder/fire(resumed = FALSE)
	if(!resumed)
		requests_processed = 0
	while(length(requests))
		if(MC_TICK_CHECK)
			return
		// No slot: get_path_to() would stoplag() waiting for one, so leave the
		// rest of the queue for the next fire instead of sleeping in this tick.
		if(!mobs || mobs.run >= mobs.lcount)
			return
		var/datum/path_request/request = requests[1]
		requests.Cut(1, 2)
		process_request(request)

/// Computes one request and hands the path to its callback. Kept separate from
/// fire() so it can be exercised outside the master controller loop.
/datum/subsystem/pathfinder/proc/process_request(datum/path_request/request)
	if(!request || !request.caller || QDELETED(request.caller) || !request.target || QDELETED(request.target))
		return FALSE
	var/list/path = get_path_to(
		request.caller,
		request.target,
		request.max_distance,
		request.mintargetdist,
		request.id,
		request.simulated_only,
		request.exclude,
		request.skip_first,
		request.diagonally,
		request.best_effort,
		request.cardinalize,
		request.smash_flags,
	)
	request.finish(path)
	requests_processed++
	return TRUE

/// One queued path request. on_finish is a /datum/callback invoked with the path
/// list (possibly empty) when the subsystem has computed it.
/datum/path_request
	var/atom/movable/caller
	var/atom/target
	var/max_distance = 30
	var/mintargetdist = 0
	var/id = null
	var/simulated_only = TRUE
	var/turf/exclude = null
	var/skip_first = TRUE
	var/diagonally = FALSE
	var/best_effort = FALSE
	var/cardinalize = FALSE
	var/smash_flags = 0
	var/callback/on_finish = null

/datum/path_request/proc/finish(list/path)
	if(on_finish)
		on_finish.invoke(path)

/datum/flowcache
	var/lcount
	var/run
	var/free
	var/list/flow

/datum/flowcache/New(n)
	. = ..()
	lcount = n
	run = 0
	free = 1
	flow = new/list(lcount)

/datum/flowcache/proc/getfree(atom/M)
	if(run < lcount)
		run += 1
		while(flow[free])
			CHECK_TICK
			free = (free % lcount) + 1
		var/t = add_timer(new /callback(src, nameof(src::toolong()), free), 15 SECONDS)
		flow[free] = t
		flow[t] = M
		return free
	else
		return 0

/datum/flowcache/proc/toolong(l)
	log_game("Pathfinder route took longer than 15 seconds, src bot [flow[flow[l]]]")
	found(l)

/datum/flowcache/proc/found(l)
	del_timer(flow[l])
	flow[l] = null
	run -= 1
