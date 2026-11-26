/obj/item/airbag
	name = "personal airbag"
	desc = "One-use protection from high-speed collisions."
	icon = 'icons/obj/items.dmi'
	icon_state = "airbag"
	item_state = "syringe_kit"
	w_class = W_CLASS_SMALL
	slot_flags = SLOT_BELT

/obj/item/airbag/proc/deploy(mob/user)
	icon = 'icons/obj/objects.dmi'
	icon_state = "airbag_deployed"
	anchored = 1
	if(loc == user)
		user.drop_item(src,get_turf(src),1)
	else
		forceMove(get_turf(src))
	if(user)
		to_chat(user, "<span class='notice'>Your [src.name] deploys!</span>")
		user.forceMove(src)
	playsound(src, 'sound/effects/bamfgas.ogg', 100, 1)

/obj/item/airbag/proc/eject_contents()
	var/turf/T = get_turf(src)
	//The airbag can land on dense piping or inside a wall. Ejecting onto that
	//turf leaves the occupant unable to move, so look for a safe neighbour.
	if(T && (T.density || T.has_dense_content(src)))
		for(var/dir in cardinal)
			var/turf/adjacent = get_step(T, dir)
			if(adjacent && !adjacent.density && !adjacent.has_dense_content())
				T = adjacent
				break
	for(var/atom/movable/AM in contents)
		AM.forceMove(T)

/obj/item/airbag/relaymove(var/mob/user, direction)
	eject_contents()
	qdel(src)

/obj/item/airbag/Destroy()
	eject_contents() //never leave occupants in nullspace if the bag is deleted
	return ..()

/obj/item/airbag/MouseDropFrom(over_object, src_location, var/turf/over_location, src_control, over_control, params)
	if(usr.incapacitated() || usr.lying)
		return
	if(!istype(over_location) || over_location.density)
		return
	if(!Adjacent(over_location) || !Adjacent(usr) || !usr.Adjacent(over_location))
		return
	for(var/atom/movable/A in over_location.contents)
		if(A.density)
			if((A == src) || ismob(A))
				continue
			return
	for(var/atom/movable/AM in contents)
		AM.forceMove(over_location)
	qdel(src)
