// Behavior tree port: state-ownership invariants.
//
// These cover the transitions the legacy Life() pipeline used to perform on its
// own (drop a target that left the view, drop object targets when damaged,
// restore object searching once nothing is left to fight) plus the cocoon guard
// that stops spin_cocoon() from nesting cocoons on every retry.
//
// The map's bottom-left corner is space and mobs spawned there are relocated, so
// the tests look for an open floor pair instead of using run_loc_bottom_left.
// Each test qdels what it creates; the framework's area cleanup cannot reach it.

/// Returns two adjacent open simulated floor turfs on z1, or null.
/proc/unit_test_bt_floor_pair()
	for(var/turf/T in block(locate(1, 1, 1), locate(world.maxx, world.maxy, 1)))
		if(!istype(T, /turf/simulated/floor) || T.density)
			continue
		var/turf/E = get_step(T, EAST)
		if(E && istype(E, /turf/simulated/floor) && !E.density)
			return list(T, E)
	return null

/datum/unit_test/behavior_tree_target_dropped_when_contained/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/giant_spider/nurse/queen_spider/Q = new(pair[1])
	var/obj/item/device/radio/intercom/IC = new(pair[2])
	if(!Q.ai_controller)
		qdel(IC)
		qdel(Q)
		return fail("the queen spider has no AI controller")

	Q.ai_controller.blackboard[BB_TARGET] = IC
	// Legacy AttackTarget() dropped targets that were no longer in ListTargets().
	var/obj/effect/spider/cocoon/C = new(get_turf(IC))
	IC.forceMove(C)
	for(var/i in 1 to 3)
		Q.ai_controller:SelectBehaviors(1)
		if(Q.ai_controller.blackboard[BB_TARGET] != IC)
			qdel(IC)
			qdel(C)
			qdel(Q)
			return
	qdel(IC)
	qdel(C)
	qdel(Q)
	fail("a cocooned target stayed on the blackboard")

/datum/unit_test/behavior_tree_damage_drops_object_target/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/giant_spider/nurse/queen_spider/Q = new(pair[1])
	var/obj/item/device/radio/intercom/IC = new(pair[2])
	if(!Q.ai_controller)
		qdel(IC)
		qdel(Q)
		return fail("the queen spider has no AI controller")

	Q.ai_controller.blackboard[BB_TARGET] = IC
	Q.adjustBruteLoss(10)
	if(Q.search_objects)
		fail("damage did not suspend object searching")
	if(Q.ai_controller.blackboard[BB_TARGET])
		fail("the object target stayed on the blackboard after damage")
	if(!Q.ai_search_objects_suspended)
		fail("the suspended flag was not set")
	qdel(IC)
	qdel(Q)

/datum/unit_test/behavior_tree_restores_object_search/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/giant_spider/nurse/queen_spider/Q = new(pair[1])
	var/datum/ai_controller/controller = new(Q)
	// A prey type that is not in the test world: no candidates, so the leaf takes
	// the "nothing left to fight" path (legacy LoseAggro()).
	var/datum/bt_node/ai_behavior/acquire_target/node = new
	node.target_source_type = /datum/target_source/prey
	node.target_source_config = list("prey_type" = /mob/living/simple_animal/hostile/monster/cyber_horror)

	Q.search_objects = 0
	Q.ai_search_objects_suspended = TRUE
	node.perform(1, controller)
	if(Q.search_objects != initial(Q.search_objects))
		fail("object searching was not restored once no target was left")
	if(Q.ai_search_objects_suspended)
		fail("the suspended flag was not cleared")
	qdel(node)
	qdel(controller)
	qdel(Q)

/datum/unit_test/behavior_tree_cocoon_guard/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/turf/target_turf = pair[2]
	var/mob/living/simple_animal/hostile/giant_spider/nurse/queen_spider/Q = new(pair[1])
	var/obj/item/weapon/reagent_containers/food/snacks/cracker/S = new(target_turf)
	new /obj/effect/spider/cocoon(target_turf)
	var/cocoons_before = 0
	for(var/obj/effect/spider/cocoon/found in target_turf)
		cocoons_before++

	// The guard must return before do_after(), so this call is instant and the
	// snack is not swallowed by a second, nested cocoon.
	Q.spin_cocoon(S)
	if(S.loc != target_turf)
		fail("a target on an already cocooned turf was moved again")
	var/cocoons_after = 0
	for(var/obj/effect/spider/cocoon/found in target_turf)
		cocoons_after++
	if(cocoons_after != cocoons_before)
		fail("spin_cocoon nested cocoons ([cocoons_before] -> [cocoons_after])")
	for(var/obj/effect/spider/cocoon/found in target_turf)
		qdel(found)
	qdel(S)
	qdel(Q)

/datum/unit_test/behavior_tree_attack_cadence/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/giant_spider/nurse/queen_spider/Q = new(pair[1])
	var/mob/living/simple_animal/mouse/target = new(pair[2])
	// Keep the victim alive: a dead target makes the nurse cocoon it (5 s do_after)
	// and turns the cadence check into a slow test.
	target.maxHealth = 100000
	target.health = 100000
	var/datum/ai_controller/controller = new(Q)
	var/datum/bt_node/ai_behavior/attack_target/node = new
	controller.blackboard[BB_TARGET] = target

	// Legacy hostile Life() attacked once per 2 s tick; the first attack lands and
	// starts the cooldown, the next tick must not attack again.
	node.do_attack(controller, target)
	if(node.next_attack_time <= world.time)
		fail("the first attack did not start the cooldown")
	var/health_after_first = target.health
	node.do_attack(controller, target)
	if(target.health != health_after_first)
		fail("the leaf attacked twice inside the legacy 2 s cadence")
	if(node.next_attack_time <= world.time)
		fail("the attack cooldown was not refreshed")
	qdel(node)
	qdel(controller)
	qdel(target)
	qdel(Q)

/datum/unit_test/behavior_tree_movement_cadence/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/bear/B = new(pair[1])
	B.move_to_delay = 2
	var/datum/ai_controller/controller = new(B)
	var/datum/ai_movement/basic/movement = controller.ai_movement
	if(!istype(movement))
		qdel(B)
		return fail("the controller has no basic movement adapter")

	// move_to_delay is in world ticks, exactly like walk_to()/Goto() before the
	// port, so the adapter interval is move_to_delay * world.tick_lag.
	var/expected = 2 * world.tick_lag
	var/actual = movement.get_step_interval(controller)
	if(abs(actual - expected) > 0.001)
		fail("step interval [actual] does not match the legacy [expected] for move_to_delay 2")
	qdel(controller)
	qdel(B)

/// The movement adapter must never spend more than one step in a single world
/// tick: the old step-credit loop turned a whole second of walking into an
/// instant teleport during the planning tick.
/datum/unit_test/behavior_tree_movement_no_burst/start()
	// Other tests qdel mobs between ticks; a deferred qdel still blocks its turf,
	// so look for a pair that is actually clear instead of trusting the type.
	var/turf/from_turf = null
	var/turf/to_turf = null
	for(var/turf/T in block(locate(1, 1, 1), locate(world.maxx, world.maxy, 1)))
		if(!istype(T, /turf/simulated/floor) || is_blocked_turf(T))
			continue
		var/turf/E = get_step(T, EAST)
		if(E && istype(E, /turf/simulated/floor) && !is_blocked_turf(E))
			from_turf = T
			to_turf = E
			break
	if(!from_turf)
		return fail("no clear floor pair on z1")
	var/mob/living/simple_animal/hostile/bear/B = new(from_turf)
	B.move_to_delay = 2
	var/datum/ai_controller/controller = new(B)
	var/datum/ai_movement/basic/movement = controller.ai_movement
	if(!istype(movement) || !SSpathfinder)
		qdel(controller)
		qdel(B)
		return fail("the movement adapter or the pathfinder subsystem is missing")

	if(!movement.start_moving_towards(controller, to_turf))
		qdel(controller)
		qdel(B)
		return fail("the adapter could not start moving")
	if(!(controller in ai_movement_active))
		qdel(controller)
		qdel(B)
		return fail("the moving controller was not registered with SSai_movement")

	// The path may start one tile away; a map mob can also wander onto the
	// destination while get_path_to() stoplag()s, so do not require the Move to
	// succeed. The invariant is that only one step is attempted per tick.
	var/moved_first = movement.process(controller)
	var/next_due = movement.next_step_time[controller]
	var/turf/after_first = get_turf(B)
	var/moved_second = movement.process(controller)
	var/turf/after_second = get_turf(B)
	var/failure = null
	if(isnull(next_due) || next_due <= world.time)
		failure = "the adapter did not schedule the next step for a later tick"
	else if(moved_second || after_second != after_first)
		failure = "the adapter spent more than one step in the same world tick"
	else if(!moved_first && !movement.take_blocked(controller))
		failure = "a refused step neither moved the pawn nor reported a blocker"

	movement.stop_moving_towards(controller)
	if(controller in ai_movement_active)
		failure = failure || "stop_moving_towards() left the controller in the movement ticker"
	qdel(controller)
	qdel(B)
	if(failure)
		fail(failure)

/// Ranged mobs keep the legacy chase: a goliath with no retreat distance has to
/// close in while its tentacle attack cools down, not hold position at range.
/// A cached path stays valid while the target is still on the turf the path was
/// built for. Re-pathing on a step count made crowds recompute A* every second
/// against a target that had not moved.
/// An open corridor uses the straight-line route instead of A*: the path is
/// walkable, cardinal and ends adjacent to a melee prey. An obstacle in the line
/// removes the direct option so the caller falls back to get_path_to().
/datum/unit_test/behavior_tree_direct_path/start()
	var/turf/base = null
	var/turf/prey_turf = null
	for(var/turf/T in block(locate(1, 1, 1), locate(world.maxx, world.maxy, 1)))
		if(!istype(T, /turf/simulated/floor) || T.density)
			continue
		var/turf/candidate = T
		var/clear = TRUE
		for(var/i in 1 to 4)
			candidate = get_step(candidate, EAST)
			if(!candidate || !istype(candidate, /turf/simulated/floor) || is_blocked_turf(candidate))
				clear = FALSE
				break
		if(clear)
			base = T
			prey_turf = candidate
			break
	if(!base)
		return fail("no clear four-tile corridor on z1")

	var/mob/living/simple_animal/hostile/bear/B = new(base)
	var/mob/living/carbon/monkey/prey = new(prey_turf)
	var/datum/ai_controller/controller = new(B)
	var/datum/ai_movement/basic/movement = controller.ai_movement
	if(!istype(movement))
		qdel(controller)
		qdel(prey)
		qdel(B)
		return fail("the controller has no basic movement adapter")

	var/failure = null
	var/list/path = movement.try_direct_path(controller, prey)
	if(!islist(path))
		failure = "the open corridor did not produce a direct path"
	else if(length(path) != 3)
		failure = "the direct path covered [length(path)] steps instead of 3"
	else
		var/turf/middle = get_step(base, EAST)
		var/obj/structure/table/blocker = new(middle)
		if(movement.try_direct_path(controller, prey))
			failure = "a blocked corridor still produced a direct path"
		qdel(blocker)

	qdel(controller)
	qdel(prey)
	qdel(B)
	if(failure)
		fail(failure)

/datum/unit_test/behavior_tree_path_reused_while_goal_unchanged/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/bear/B = new(pair[1])
	var/mob/living/carbon/monkey/prey = new(pair[2])
	var/datum/ai_controller/controller = new(B)
	var/datum/ai_movement/basic/movement = controller.ai_movement
	if(!istype(movement))
		qdel(controller)
		qdel(prey)
		qdel(B)
		return fail("the controller has no basic movement adapter")

	var/failure = null
	if(!movement.start_moving_towards(controller, prey))
		failure = "the adapter could not start moving"
	else if(movement.needs_repath(controller, prey))
		failure = "the cached path was invalidated while the target stood still"
	else
		prey.forceMove(pair[1])
		if(!movement.needs_repath(controller, prey))
			failure = "moving the target out of the path goal did not invalidate the path"

	movement.stop_moving_towards(controller)
	qdel(controller)
	qdel(prey)
	qdel(B)
	if(failure)
		fail(failure)

/datum/unit_test/behavior_tree_ranged_chases_to_min_distance/start()
	var/turf/base = null
	var/turf/prey_turf = null
	for(var/turf/T in block(locate(1, 1, 1), locate(world.maxx, world.maxy, 1)))
		if(!istype(T, /turf/simulated/floor) || T.density)
			continue
		var/turf/candidate = T
		var/clear = TRUE
		for(var/i in 1 to 4)
			candidate = get_step(candidate, EAST)
			if(!candidate || !istype(candidate, /turf/simulated/floor) || is_blocked_turf(candidate))
				clear = FALSE
				break
		if(clear)
			base = T
			prey_turf = candidate
			break
	if(!base)
		return fail("no clear four-tile corridor on z1")

	var/mob/living/simple_animal/hostile/asteroid/goliath/goliath = new(base)
	var/mob/living/carbon/monkey/prey = new(prey_turf)
	prey.maxHealth = 1000000
	prey.health = 1000000
	var/datum/ai_controller/controller = goliath.ai_controller
	// Lazy controller install happens on the first Life(); do it explicitly so a
	// missing tree fails here instead of being hidden by a null check.
	if(!controller)
		controller = goliath.use_hostile_tree()
	goliath.GiveTarget(prey)
	// The first tick may take the ranged attack branch; the second must chase.
	controller.SelectBehaviors(1)
	controller.SelectBehaviors(1)

	var/failure = null
	if(get_dist(goliath, prey) <= goliath.minimum_distance)
		failure = "the test setup put the prey inside minimum_distance"
	else if(!controller.ai_movement.has_path(controller) && !(controller in ai_movement_active))
		failure = "the ranged goliath held position instead of chasing"

	controller.ai_movement.stop_moving_towards(controller)
	qdel(controller)
	qdel(prey)
	qdel(goliath)
	if(failure)
		fail(failure)

/datum/unit_test/behavior_tree_pathfinder_budget/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/bear/B = new(pair[1])
	var/datum/ai_controller/controller = new(B)
	var/datum/ai_movement/basic/movement = controller.ai_movement
	if(!SSpathfinder || !SSpathfinder.mobs || !istype(movement))
		qdel(controller)
		qdel(B)
		return fail("the pathfinder cache or movement adapter is missing")

	// Pretend every pathfinder slot is taken. get_path_to() would stoplag() until
	// one frees up; the adapter must take the single greedy step instead.
	var/old_run = SSpathfinder.mobs.run
	SSpathfinder.mobs.run = SSpathfinder.mobs.lcount
	var/started = movement.start_moving_towards(controller, pair[2])
	SSpathfinder.mobs.run = old_run
	if(!started)
		fail("the adapter did not start moving on a busy pathfinder")
	var/list/path = movement.paths[controller]
	if(!islist(path) || length(path) != 1)
		fail("the adapter did not fall back to a single greedy step on a busy pathfinder")
	qdel(controller)
	qdel(B)

/datum/unit_test/behavior_tree_async_path
	var/received = FALSE
	var/list/received_path = null

/datum/unit_test/behavior_tree_async_path/proc/on_path(list/path)
	received = TRUE
	received_path = path

/datum/unit_test/behavior_tree_async_path/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	if(!SSpathfinder)
		return fail("the pathfinder subsystem is missing")
	var/mob/living/simple_animal/hostile/bear/B = new(pair[1])
	var/datum/path_request/request = new
	request.caller = B
	request.target = pair[2]
	request.skip_first = FALSE
	request.on_finish = new /callback(src, nameof(src::on_path()))
	SSpathfinder.queue_path(request)
	if(!(request in SSpathfinder.requests))
		qdel(B)
		return fail("the async request was not queued")
	SSpathfinder.requests -= request
	SSpathfinder.process_request(request)
	if(!received)
		fail("the async path callback did not run")
	else if(!islist(received_path) || !length(received_path))
		fail("the async request returned no path")
	qdel(B)

/datum/unit_test/behavior_tree_food_target_reachability/start()
	var/list/pair = unit_test_bt_floor_pair()
	if(!pair)
		return fail("no open floor pair on z1")
	var/mob/living/simple_animal/hostile/giant_spider/nurse/queen_spider/Q = new(pair[1])
	var/mob/living/simple_animal/mouse/holder = new(pair[2])
	var/obj/item/weapon/reagent_containers/food/snacks/cracker/snack = new(holder)
	var/datum/target_source/food/source = new

	// A snack in a visible mob's hand is a valid food target...
	if(!source.is_reachable_target(null, Q, snack, 7))
		fail("a snack held by a visible mob was considered unreachable")
	// ...but once it is inside a container it is gone, like any other target.
	var/obj/effect/spider/cocoon/C = new(get_turf(holder))
	snack.forceMove(C)
	if(source.is_reachable_target(null, Q, snack, 7))
		fail("a contained snack stayed reachable")
	qdel(snack)
	qdel(C)
	qdel(holder)
	qdel(Q)
