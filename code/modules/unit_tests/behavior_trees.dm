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
