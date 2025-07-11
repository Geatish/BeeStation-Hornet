SUBSYSTEM_DEF(job)
	name = "Jobs"
	init_order = INIT_ORDER_JOBS
	flags = SS_NO_FIRE

	var/list/occupations = list()		//List of all jobs
	var/list/datum/job/name_occupations = list()	//Dict of all jobs, keys are titles
	var/list/type_occupations = list()	//Dict of all jobs, keys are types
	var/list/unassigned = list()		//Players who need jobs
	var/initial_players_to_assign = 0 	//used for checking against population caps

	var/list/prioritized_jobs = list()
	var/list/latejoin_trackers = list()	//Don't read this list, use GetLateJoinTurfs() instead

	var/overflow_role = JOB_NAME_ASSISTANT

	var/list/level_order = list(JP_HIGH,JP_MEDIUM,JP_LOW)

	var/spare_id_safe_code = ""

	var/list/chain_of_command = list(
		"Captain" = 1,				//Not used yet but captain is first in chain_of_command
		"Head of Personnel" = 2,
		"Research Director" = 3,
		"Chief Engineer" = 4,
		"Chief Medical Officer" = 5,
		"Head of Security" = 6)

	//Crew Objective stuff
	var/list/crew_obj_list = list()
	var/list/crew_obj_jobs = list()

	/// jobs that are not allowed in HoP job manager
	var/list/job_manager_blacklisted = list(
		JOB_NAME_AI,
		JOB_NAME_ASSISTANT,
		JOB_NAME_CYBORG,
		JOB_NAME_POSIBRAIN,
		JOB_NAME_CAPTAIN,
		JOB_NAME_HEADOFPERSONNEL,
		JOB_NAME_HEADOFSECURITY,
		JOB_NAME_CHIEFENGINEER,
		JOB_NAME_RESEARCHDIRECTOR,
		JOB_NAME_CHIEFMEDICALOFFICER,
		JOB_NAME_DEPUTY,
		JOB_NAME_GIMMICK)

	/// If TRUE, some player has been assigned Captaincy or Acting Captaincy at some point during the shift and has been given the spare ID safe code.
	var/assigned_captain = FALSE
	/// Whether the emergency safe code has been requested via a comms console on shifts with no Captain or Acting Captain.
	var/safe_code_requested = FALSE
	/// Timer ID for the emergency safe code request.
	var/safe_code_timer_id
	/// The loc to which the emergency safe code has been requested for delivery.
	var/turf/safe_code_request_loc

/datum/controller/subsystem/job/Initialize()
	if(!occupations.len)
		SetupOccupations()
	if(CONFIG_GET(flag/load_jobs_from_txt))
		LoadJobs()
	set_overflow_role(CONFIG_GET(string/overflow_job))

	spare_id_safe_code = "[rand(0,9)][rand(0,9)][rand(0,9)][rand(0,9)][rand(0,9)]"

	crew_obj_list = subtypesof(/datum/objective/crew)
	for(var/type as() in crew_obj_list)
		// Unfortunately, this is necessary because initial() doesn't work on lists
		var/datum/objective/crew/obj = new type
		var/list/obj_jobs = obj.jobs
		if(!istype(obj_jobs))
			obj_jobs = list(obj_jobs)
		for(var/job in obj_jobs)
			crew_obj_jobs["[job]"] += list(type)
		qdel(obj)

	return SS_INIT_SUCCESS

/datum/controller/subsystem/job/Recover()
	occupations = SSjob.occupations
	name_occupations = SSjob.name_occupations
	type_occupations = SSjob.type_occupations
	unassigned = SSjob.unassigned
	initial_players_to_assign = SSjob.initial_players_to_assign

	prioritized_jobs = SSjob.prioritized_jobs
	latejoin_trackers = SSjob.latejoin_trackers

	overflow_role = SSjob.overflow_role

	spare_id_safe_code = SSjob.spare_id_safe_code
	crew_obj_list = SSjob.crew_obj_list
	crew_obj_jobs = SSjob.crew_obj_jobs

	job_manager_blacklisted = SSjob.job_manager_blacklisted

/datum/controller/subsystem/job/proc/set_overflow_role(new_overflow_role)
	var/datum/job/new_overflow = GetJob(new_overflow_role)
	if(!new_overflow || new_overflow.lock_flags)
		CRASH("[new_overflow_role] was used for an overflow role, but it's not allowed. BITFLAG: [new_overflow?.lock_flags]")
	var/cap = CONFIG_GET(number/overflow_cap)

	new_overflow.allow_bureaucratic_error = FALSE
	new_overflow.spawn_positions = cap
	new_overflow.total_positions = cap

	if(new_overflow_role != overflow_role)
		var/datum/job/old_overflow = GetJob(overflow_role)
		old_overflow.allow_bureaucratic_error = initial(old_overflow.allow_bureaucratic_error)
		old_overflow.spawn_positions = initial(old_overflow.spawn_positions)
		old_overflow.total_positions = initial(old_overflow.total_positions)
		overflow_role = new_overflow_role
		JobDebug("Overflow role set to : [new_overflow_role]")

/datum/controller/subsystem/job/proc/SetupOccupations(faction = "Station")
	occupations = list()
	var/list/all_jobs = subtypesof(/datum/job)
	if(!all_jobs.len)
		to_chat(world, span_boldannounce("Error setting up jobs, no job datums found."))
		return 0

	for(var/datum/job/each_job as anything in all_jobs)
		each_job = new each_job()
		if(each_job.faction != faction)
			continue
		occupations += each_job
		name_occupations[each_job.title] = each_job
		type_occupations[each_job.type] = each_job
	if(SSmapping.map_adjustment)
		SSmapping.map_adjustment.job_change()
		log_world("Applied '[SSmapping.map_adjustment.map_file_name]' map adjustment: job_change()")

	return 1


/datum/controller/subsystem/job/proc/GetJob(rank)
	RETURN_TYPE(/datum/job)
	if(!rank)
		CRASH("proc has taken no job name")
	if(!occupations.len)
		SetupOccupations()
	if(!name_occupations[rank])
		CRASH("job name [rank] is not valid")
	return name_occupations[rank]

/datum/controller/subsystem/job/proc/GetJobType(jobtype)
	RETURN_TYPE(/datum/job)
	if(!jobtype)
		CRASH("proc has taken no job type")
	if(!occupations.len)
		SetupOccupations()
	if(!type_occupations[jobtype])
		CRASH("job type [jobtype] is not valid")
	return type_occupations[jobtype]

/datum/controller/subsystem/job/proc/GetJobActiveDepartment(rank)
	if(!rank)
		CRASH("proc has taken no job name")
	if(!occupations.len)
		SetupOccupations()
	if(!name_occupations[rank])
		CRASH("job name [rank] is not valid")
	var/datum/job/J = name_occupations[rank]
	return J.departments

/datum/controller/subsystem/job/proc/AssignRole(mob/dead/new_player/authenticated/player, rank, latejoin = FALSE)
	JobDebug("Running AR, Player: [player], Rank: [rank], LJ: [latejoin]")
	if(player?.mind && rank)
		var/datum/job/job = GetJob(rank)
		if(!job || job.lock_flags)
			return FALSE
		if(QDELETED(player) || is_banned_from(player.ckey, rank))
			return FALSE
		if(!job.player_old_enough(player.client))
			return FALSE
		if(job.required_playtime_remaining(player.client))
			return FALSE
		var/position_limit = job.total_positions
		if(!latejoin)
			position_limit = job.spawn_positions
		JobDebug("Player: [player] is now Rank: [rank], JCP:[job.current_positions], JPL:[position_limit]")
		player.mind.assigned_role = rank
		unassigned -= player
		job.current_positions++
		return TRUE
	JobDebug("AR has failed, Player: [player], Rank: [rank]")
	return FALSE

/datum/controller/subsystem/job/proc/FreeRole(rank)
	if(!rank)
		return
	JobDebug("Freeing role: [rank]")
	var/datum/job/job = GetJob(rank)
	if(!job)
		return FALSE
	job.current_positions = max(0, job.current_positions - 1)

/datum/controller/subsystem/job/proc/FindOccupationCandidates(datum/job/job, level)
	JobDebug("Running FOC, Job: [job], Level: [level]")
	var/list/candidates = list()
	for(var/mob/dead/new_player/authenticated/player in unassigned)
		if(QDELETED(player) || is_banned_from(player.ckey, job.title))
			JobDebug("FOC isbanned failed, Player: [player]")
			continue
		if(!job.player_old_enough(player.client))
			JobDebug("FOC player not old enough, Player: [player]")
			continue
		if(job.required_playtime_remaining(player.client))
			JobDebug("FOC player not enough xp, Player: [player]")
			continue
		if(player.mind && (job.title in player.mind.restricted_roles))
			JobDebug("FOC incompatible with antagonist role, Player: [player]")
			continue
		if(player.client.prefs.job_preferences[job.title] == level)
			JobDebug("FOC pass, Player: [player], Level:[level]")
			candidates += player
	return candidates

/datum/controller/subsystem/job/proc/GiveRandomJob(mob/dead/new_player/authenticated/player)
	JobDebug("GRJ Giving random job, Player: [player]")
	. = FALSE
	for(var/datum/job/job in shuffle(occupations))
		if(!job || job.lock_flags)
			continue

		if(istype(job, GetJob(SSjob.overflow_role))) // We don't want to give him assistant, that's boring!
			continue

		if(job.title in SSdepartment.get_jobs_by_dept_id(DEPT_NAME_COMMAND)) //If you want a command position, select it!
			continue

		if(QDELETED(player))
			JobDebug("GRJ isbanned failed, Player deleted")
			break

		if(is_banned_from(player.ckey, job.title))
			JobDebug("GRJ isbanned failed, Player: [player], Job: [job.title]")
			continue

		if(!job.player_old_enough(player.client))
			JobDebug("GRJ player not old enough, Player: [player]")
			continue

		if(job.required_playtime_remaining(player.client))
			JobDebug("GRJ player not enough xp, Player: [player]")
			continue

		if(player.mind && (job.title in player.mind.restricted_roles))
			JobDebug("GRJ incompatible with antagonist role, Player: [player], Job: [job.title]")
			continue

		if((job.current_positions < job.spawn_positions) || job.spawn_positions == -1)
			JobDebug("GRJ Random job given, Player: [player], Job: [job]")
			if(AssignRole(player, job.title))
				return TRUE

/datum/controller/subsystem/job/proc/ResetOccupations()
	JobDebug("Occupations reset.")
	for(var/mob/dead/new_player/authenticated/player in GLOB.player_list)
		if((player) && (player.mind))
			player.mind.assigned_role = null
			player.mind.special_role = null
			SSpersistence.antag_rep_change[player.ckey] = 0
	SetupOccupations()
	unassigned = list()
	return


//This proc is called before the level loop of DivideOccupations() and will try to select a head, ignoring ALL non-head preferences for every level until
//it locates a head or runs out of levels to check
//This is basically to ensure that there's atleast a few heads in the round
/datum/controller/subsystem/job/proc/FillHeadPosition()
	for(var/level in level_order)
		for(var/command_position in SSdepartment.get_jobs_by_dept_id(DEPT_NAME_COMMAND))
			var/datum/job/job = GetJob(command_position)
			if(!job)
				continue
			if((job.current_positions >= job.total_positions) && job.total_positions != -1)
				continue
			var/list/candidates = FindOccupationCandidates(job, level)
			if(!candidates.len)
				continue
			var/mob/dead/new_player/authenticated/candidate = pick(candidates)
			if(AssignRole(candidate, command_position))
				return 1
	return 0


//This proc is called at the start of the level loop of DivideOccupations() and will cause head jobs to be checked before any other jobs of the same level
//This is also to ensure we get as many heads as possible
/datum/controller/subsystem/job/proc/CheckHeadPositions(level)
	for(var/command_position in SSdepartment.get_jobs_by_dept_id(DEPT_NAME_COMMAND))
		var/datum/job/job = GetJob(command_position)
		if(!job)
			continue
		if((job.current_positions >= job.total_positions) && job.total_positions != -1)
			continue
		var/list/candidates = FindOccupationCandidates(job, level)
		if(!candidates.len)
			continue
		var/mob/dead/new_player/authenticated/candidate = pick(candidates)
		AssignRole(candidate, command_position)

/datum/controller/subsystem/job/proc/FillAIPosition()
	var/ai_selected = 0
	var/datum/job/job = GetJob("AI")
	if(!job)
		return 0
	for(var/i = job.total_positions, i > 0, i--)
		for(var/level in level_order)
			var/list/candidates = list()
			candidates = FindOccupationCandidates(job, level)
			if(candidates.len)
				var/mob/dead/new_player/authenticated/candidate = pick(candidates)
				if(AssignRole(candidate, "AI"))
					ai_selected++
					break
	if(ai_selected)
		return 1
	return 0


/** Proc DivideOccupations
 *  fills var "assigned_role" for all ready players.
 *  This proc must not have any side effect besides of modifying "assigned_role".
 **/
/datum/controller/subsystem/job/proc/DivideOccupations(list/required_jobs)
	//Setup new player list and get the jobs list
	JobDebug("Running DO")

	//Holder for Triumvirate is stored in the SSticker, this just processes it
	if(SSticker.triai)
		for(var/datum/job/ai/A in occupations)
			A.spawn_positions = 3
		for(var/obj/effect/landmark/start/ai/secondary/S in GLOB.start_landmarks_list)
			S.latejoin_active = TRUE

	//Get the players who are ready
	for(var/mob/dead/new_player/authenticated/player in GLOB.player_list)
		if(player.ready == PLAYER_READY_TO_PLAY && player.mind && !player.mind.assigned_role)
			if(!player.check_preferences())
				player.ready = PLAYER_NOT_READY
			else
				unassigned += player

	initial_players_to_assign = unassigned.len

	JobDebug("DO, Len: [unassigned.len]")
	if(unassigned.len == 0)
		return validate_required_jobs(required_jobs)

	//Scale number of open security officer slots to population
	setup_officer_positions()

	//Jobs will have fewer access permissions if the number of players exceeds the threshold defined in game_options.txt
	var/mat = CONFIG_GET(number/minimal_access_threshold)
	if(mat)
		if(mat > unassigned.len)
			CONFIG_SET(flag/jobs_have_minimal_access, FALSE)
		else
			CONFIG_SET(flag/jobs_have_minimal_access, TRUE)

	//Shuffle players and jobs
	unassigned = shuffle(unassigned)

	HandleFeedbackGathering()

	//People who wants to be the overflow role, sure, go on.
	JobDebug("DO, Running Overflow Check 1")
	var/datum/job/overflow = GetJob(SSjob.overflow_role)
	var/list/overflow_candidates = FindOccupationCandidates(overflow, 3)
	JobDebug("AC1, Candidates: [overflow_candidates.len]")
	for(var/mob/dead/new_player/authenticated/player in overflow_candidates)
		JobDebug("AC1 pass, Player: [player]")
		AssignRole(player, SSjob.overflow_role)
		overflow_candidates -= player
	JobDebug("DO, AC1 end")

	//Select one head
	JobDebug("DO, Running Head Check")
	FillHeadPosition()
	JobDebug("DO, Head Check end")

	//Check for an AI
	JobDebug("DO, Running AI Check")
	FillAIPosition()
	JobDebug("DO, AI Check end")

	//Other jobs are now checked
	JobDebug("DO, Running Standard Check")


	// New job giving system by Donkie
	// This will cause lots of more loops, but since it's only done once it shouldn't really matter much at all.
	// Hopefully this will add more randomness and fairness to job giving.

	// Loop through all levels from high to low
	var/list/shuffledoccupations = shuffle(occupations)
	for(var/level in level_order)
		//Check the head jobs first each level
		CheckHeadPositions(level)

		// Loop through all unassigned players
		for(var/mob/dead/new_player/authenticated/player in unassigned)
			if(PopcapReached() && !IS_PATRON(player.ckey))
				RejectPlayer(player)

			// Loop through all jobs
			for(var/datum/job/job in shuffledoccupations) // SHUFFLE ME BABY
				if(!job || job.lock_flags)
					continue

				if(is_banned_from(player.ckey, job.title))
					JobDebug("DO isbanned failed, Player: [player], Job:[job.title]")
					continue

				if(QDELETED(player))
					JobDebug("DO player deleted during job ban check")
					break

				if(!job.player_old_enough(player.client))
					JobDebug("DO player not old enough, Player: [player], Job:[job.title]")
					continue

				if(job.required_playtime_remaining(player.client))
					JobDebug("DO player not enough xp, Player: [player], Job:[job.title]")
					continue

				if(player.mind && (job.title in player.mind.restricted_roles))
					JobDebug("DO incompatible with antagonist role, Player: [player], Job:[job.title]")
					continue

				// If the player wants that job on this level, then try give it to him.
				if(player.client.prefs.job_preferences[job.title] == level || (job.gimmick && player.client.prefs.job_preferences["Gimmick"] == level))
					// If the job isn't filled
					if((job.current_positions < job.spawn_positions) || job.spawn_positions == -1)
						JobDebug("DO pass, Player: [player], Level:[level], Job:[job.title]")
						AssignRole(player, job.title)
						unassigned -= player
						break


	JobDebug("DO, Handling unassigned.")
	// Hand out random jobs to the people who didn't get any in the last check
	// Also makes sure that they got their preference correct
	for(var/mob/dead/new_player/authenticated/player in unassigned)
		HandleUnassigned(player)

	JobDebug("DO, Handling unrejectable unassigned")
	//Mop up people who can't leave.
	for(var/mob/dead/new_player/authenticated/player in unassigned) //Players that wanted to back out but couldn't because they're antags (can you feel the edge case?)
		if(!GiveRandomJob(player))
			if(!AssignRole(player, SSjob.overflow_role)) //If everything is already filled, make them an assistant
				return FALSE //Living on the edge, the forced antagonist couldn't be assigned to overflow role (bans, client age) - just reroll

	return validate_required_jobs(required_jobs)

/datum/controller/subsystem/job/proc/validate_required_jobs(list/required_jobs)
	if(!required_jobs.len)
		return TRUE
	for(var/required_group in required_jobs)
		var/group_ok = TRUE
		for(var/rank in required_group)
			var/datum/job/J = GetJob(rank)
			if(!J)
				SSticker.mode.setup_error = "Invalid job [rank] in gamemode required jobs."
				return FALSE
			if(J.current_positions < required_group[rank])
				group_ok = FALSE
				break
		if(group_ok)
			return TRUE
	SSticker.mode.setup_error = "Required jobs not present."
	return FALSE

//We couldn't find a job from prefs for this guy.
/datum/controller/subsystem/job/proc/HandleUnassigned(mob/dead/new_player/authenticated/player)
	var/jobless_role = player.client.prefs.read_character_preference(/datum/preference/choiced/jobless_role)

	if(PopcapReached() && !IS_PATRON(player.ckey))
		RejectPlayer(player)
		return

	switch (jobless_role)
		if (BEOVERFLOW)
			var/datum/job/overflow_role_datum = GetJob(overflow_role)
			if(!istype(overflow_role_datum))
				stack_trace("Invalid overflow_role set ([overflow_role]), please make sure it matches a valid job datum.")
				RejectPlayer(player)
			else
				var/allowed_to_be_a_loser = !is_banned_from(player.ckey, overflow_role_datum.title)
				if(QDELETED(player) || !allowed_to_be_a_loser)
					RejectPlayer(player)
				else
					if(!AssignRole(player, overflow_role_datum.title))
						RejectPlayer(player)
		if (BERANDOMJOB)
			if(!GiveRandomJob(player))
				RejectPlayer(player)
		if (RETURNTOLOBBY)
			RejectPlayer(player)
		else //Something gone wrong if we got here.
			var/message = "DO: [player] fell through handling unassigned"
			JobDebug(message)
			log_game(message)
			message_admins(message)
			RejectPlayer(player)


//Gives the player the stuff he should have with his rank
/datum/controller/subsystem/job/proc/EquipRank(mob/M, rank, joined_late = FALSE)
	var/mob/dead/new_player/authenticated/newplayer
	var/mob/living/living_mob

	if(!joined_late)
		newplayer = M
		living_mob = newplayer.new_character
	else
		living_mob = M

	var/datum/job/job = GetJob(rank)

	living_mob.job = rank

	//If we joined at roundstart we should be positioned at our workstation
	if(!joined_late)
		var/spawning_handled = FALSE
		var/obj/S = null
		if(HAS_TRAIT(SSstation, STATION_TRAIT_LATE_ARRIVALS) && job.random_spawns_possible)
			SendToLateJoin(living_mob)
			spawning_handled = TRUE
		else if(HAS_TRAIT(SSstation, STATION_TRAIT_RANDOM_ARRIVALS) && job.random_spawns_possible)
			DropLandAtRandomHallwayPoint(living_mob)
			spawning_handled = TRUE
		else if(HAS_TRAIT(SSstation, STATION_TRAIT_HANGOVER) && job.random_spawns_possible)
			SpawnLandAtRandom(living_mob, (typesof(/area/hallway) | typesof(/area/crew_quarters/bar) | typesof(/area/crew_quarters/dorms)))
			spawning_handled = TRUE
		else if(length(GLOB.jobspawn_overrides[rank]))
			S = pick(GLOB.jobspawn_overrides[rank])
		else
			for(var/obj/effect/landmark/start/sloc in GLOB.start_landmarks_list)
				if(sloc.name != rank)
					S = sloc //so we can revert to spawning them on top of eachother if something goes wrong
					continue
				if(locate(/mob/living) in sloc.loc)
					continue
				S = sloc
				sloc.used = TRUE
				break
		if(S)
			S.JoinPlayerHere(living_mob, FALSE)
		if(!S && !spawning_handled) //if there isn't a spawnpoint send them to latejoin, if there's no latejoin go yell at your mapper
			log_world("Couldn't find a round start spawn point for [rank]")
			SendToLateJoin(living_mob)


	if(living_mob.mind)
		living_mob.mind.assigned_role = rank
	to_chat(M, "<b>You are the [rank].</b>")
	if(job)
		var/new_mob = job.equip(living_mob, null, null, joined_late , null, M.client)
		if(ismob(new_mob))
			living_mob = new_mob
			if(!joined_late)
				newplayer.new_character = living_mob
			else
				M = living_mob
		else
			if(!isnull(new_mob)) //Detect fail condition on equip
			//if equip() is somehow able to fail, send them back to lobby
				var/mob/dead/new_player/authenticated/NP = new()
				NP.ckey = M.client.ckey
				qdel(M)
				to_chat(M, "Error equipping [rank]. Returning to lobby.</b>")
				return null
		SSpersistence.antag_rep_change[M.client.ckey] += job.GetAntagRep()

		if(M.client.holder)
			if(CONFIG_GET(flag/auto_deadmin_players) || M.client?.prefs.read_player_preference(/datum/preference/toggle/deadmin_always))
				M.client.holder.auto_deadmin()
			else
				handle_auto_deadmin_roles(M.client, rank)
		to_chat(M, "<b>As the [rank] you answer directly to [job.supervisors]. Special circumstances may change this.</b>")
		job.radio_help_message(M)
		if(job.req_admin_notify)
			to_chat(M, "<b>You are playing a job that is important for Game Progression. If you have to disconnect, please notify the admins via adminhelp.</b>")
		if(CONFIG_GET(number/minimal_access_threshold))
			to_chat(M, span_notice("<B>As this station was initially staffed with a [CONFIG_GET(flag/jobs_have_minimal_access) ? "full crew, only your job's necessities" : "skeleton crew, additional access may"] have been added to your ID card.</B>"))
	if(ishuman(living_mob))
		var/mob/living/carbon/human/wageslave = living_mob
		if(wageslave.mind?.account_id)
			living_mob.add_memory("Your account ID is [wageslave.mind.account_id].")
	if(job && living_mob)
		job.after_spawn(living_mob, M, joined_late, M.client) // note: this happens before the mob has a key! M will always have a client, living_mob might not.

	if(living_mob.mind && !living_mob.mind.crew_objectives.len)
		give_crew_objective(living_mob.mind, M)

	return living_mob

/datum/controller/subsystem/job/proc/handle_auto_deadmin_roles(client/C, rank)
	if(!C?.holder)
		return TRUE
	var/datum/job/job = GetJob(rank)
	if(!job)
		return
	if((job.auto_deadmin_role_flags & DEADMIN_POSITION_HEAD) && (CONFIG_GET(flag/auto_deadmin_heads) || C.prefs?.read_player_preference(/datum/preference/toggle/deadmin_position_head)))
		return C.holder.auto_deadmin()
	else if((job.auto_deadmin_role_flags & DEADMIN_POSITION_SECURITY) && (CONFIG_GET(flag/auto_deadmin_security) || C.prefs?.read_player_preference(/datum/preference/toggle/deadmin_position_security)))
		return C.holder.auto_deadmin()
	else if((job.auto_deadmin_role_flags & DEADMIN_POSITION_SILICON) && (CONFIG_GET(flag/auto_deadmin_silicons) || C.prefs?.read_player_preference(/datum/preference/toggle/deadmin_position_silicon))) //in the event there's ever psuedo-silicon roles added, ie synths.
		return C.holder.auto_deadmin()

/datum/controller/subsystem/job/proc/setup_officer_positions()
	var/datum/job/J = SSjob.GetJob("Security Officer")
	if(!J)
		CRASH("setup_officer_positions(): Security officer job is missing")

	var/ssc = CONFIG_GET(number/security_scaling_coeff)
	if(ssc > 0)
		if(J.spawn_positions > 0)
			var/officer_positions = min(12, max(J.spawn_positions, round(unassigned.len / ssc))) //Scale between configured minimum and 12 officers
			JobDebug("Setting open security officer positions to [officer_positions]")
			J.total_positions = officer_positions
			J.spawn_positions = officer_positions

	//Spawn some extra eqipment lockers if we have more than 5 officers
	var/equip_needed = J.total_positions
	if(equip_needed < 0) // -1: infinite available slots
		equip_needed = 12
	for(var/i=equip_needed-5, i>0, i--)
		if(GLOB.secequipment.len)
			var/spawnloc = GLOB.secequipment[1]
			new /obj/structure/closet/secure_closet/security/sec(spawnloc)
			GLOB.secequipment -= spawnloc
		else //We ran out of spare locker spawns!
			break


/datum/controller/subsystem/job/proc/LoadJobs()
	var/jobstext = rustg_file_read("[global.config.directory]/jobs.txt")
	for(var/datum/job/J in occupations)
		if(J.gimmick) //gimmick job slots are dependant on random maint
			continue
		var/regex/jobs = new("[J.title]=(-1|\\d+),(-1|\\d+)")
		if(jobs.Find(jobstext))
			J.total_positions = text2num(jobs.group[1])
			J.spawn_positions = text2num(jobs.group[2])
		else
			log_runtime("Error in /datum/controller/subsystem/job/proc/LoadJobs: Failed to locate job of title [J.title] in jobs.txt")

/datum/controller/subsystem/job/proc/HandleFeedbackGathering()
	for(var/datum/job/job in occupations)
		var/high = 0 //high
		var/medium = 0 //medium
		var/low = 0 //low
		var/never = 0 //never
		var/banned = 0 //banned
		var/young = 0 //account too young
		for(var/mob/dead/new_player/authenticated/player in GLOB.player_list)
			if(job.lock_flags)
				continue
			if(!(player.ready == PLAYER_READY_TO_PLAY && player.mind && !player.mind.assigned_role))
				continue //This player is not ready
			if(is_banned_from(player.ckey, job.title) || QDELETED(player))
				banned++
				continue
			if(!job.player_old_enough(player.client))
				young++
				continue
			if(job.required_playtime_remaining(player.client))
				young++
				continue
			switch(player.client.prefs.job_preferences[job.title])
				if(JP_HIGH)
					high++
				if(JP_MEDIUM)
					medium++
				if(JP_LOW)
					low++
				else
					never++
		SSblackbox.record_feedback("nested tally", "job_preferences", high, list("[job.title]", "high"))
		SSblackbox.record_feedback("nested tally", "job_preferences", medium, list("[job.title]", "medium"))
		SSblackbox.record_feedback("nested tally", "job_preferences", low, list("[job.title]", "low"))
		SSblackbox.record_feedback("nested tally", "job_preferences", never, list("[job.title]", "never"))
		SSblackbox.record_feedback("nested tally", "job_preferences", banned, list("[job.title]", "banned"))
		SSblackbox.record_feedback("nested tally", "job_preferences", young, list("[job.title]", "young"))

/datum/controller/subsystem/job/proc/PopcapReached()
	var/hpc = CONFIG_GET(number/hard_popcap)
	var/epc = CONFIG_GET(number/extreme_popcap)
	if(hpc || epc)
		var/relevent_cap = max(hpc, epc)
		if((initial_players_to_assign - unassigned.len) >= relevent_cap)
			return 1
	return 0

/datum/controller/subsystem/job/proc/RejectPlayer(mob/dead/new_player/authenticated/player)
	if(player.mind && player.mind.special_role)
		return
	if(PopcapReached() && !IS_PATRON(player.ckey))
		JobDebug("Popcap overflow Check observer located, Player: [player]")
	JobDebug("Player rejected :[player]")
	to_chat(player, "<b>You have failed to qualify for any job you desired.</b>")
	unassigned -= player
	player.ready = PLAYER_NOT_READY


/atom/proc/JoinPlayerHere(mob/M, buckle)
	// By default, just place the mob on the same turf as the marker or whatever.
	M.forceMove(get_turf(src))

/obj/structure/chair/JoinPlayerHere(mob/M, buckle)
	// Placing a mob in a chair will attempt to buckle it if buckle is set
	..()
	if (buckle)
		buckle_mob(M, FALSE, FALSE)

/datum/controller/subsystem/job/proc/SendToLateJoin(mob/M, buckle = TRUE)
	var/atom/destination
	if(M.mind && M.mind.assigned_role && length(GLOB.jobspawn_overrides[M.mind.assigned_role])) //We're doing something special today.
		destination = pick(GLOB.jobspawn_overrides[M.mind.assigned_role])
		destination.JoinPlayerHere(M, FALSE)
		return

	if(latejoin_trackers.len)
		destination = pick(latejoin_trackers)
		destination.JoinPlayerHere(M, buckle)
		return

	//bad mojo
	var/area/shuttle/arrival/arrivals_area = GLOB.areas_by_type[/area/shuttle/arrival]
	if(arrivals_area)
		//first check if we can find a chair
		var/obj/structure/chair/C = locate() in arrivals_area
		if(C)
			C.JoinPlayerHere(M, buckle)
			return

		//last hurrah
		var/list/turf/available_turfs = list()
		for(var/turf/arrivals_turf in arrivals_area)
			if(!arrivals_turf.is_blocked_turf(TRUE))
				available_turfs += arrivals_turf
		if(available_turfs.len)
			destination = pick(available_turfs)
			destination.JoinPlayerHere(M, FALSE)
			return

	//pick an open spot on arrivals and dump em
	var/list/arrivals_turfs = shuffle(get_area_turfs(/area/shuttle/arrival))
	if(arrivals_turfs.len)
		for(var/turf/T in arrivals_turfs)
			if(!T.is_blocked_turf(TRUE))
				T.JoinPlayerHere(M, FALSE)
				return
		//last chance, pick ANY spot on arrivals and dump em
		destination = arrivals_turfs[1]
		destination.JoinPlayerHere(M, FALSE)
	else
		var/msg = "Unable to send mob [M] to late join!"
		message_admins(msg)
		CRASH(msg)

///Spawns specified mob at a random spot in the hallways
/datum/controller/subsystem/job/proc/SpawnLandAtRandom(mob/living/living_mob, areas = typesof(/area/hallway))
	var/turf/spawn_turf = get_safe_random_station_turfs(areas)

	if(!spawn_turf)
		SendToLateJoin(living_mob)
		return

	living_mob.forceMove(spawn_turf)

///Lands specified mob at a random spot in the hallways
/datum/controller/subsystem/job/proc/DropLandAtRandomHallwayPoint(mob/living/living_mob)
	var/turf/spawn_turf = get_safe_random_station_turfs(typesof(/area/hallway))

	if(!spawn_turf)
		SendToLateJoin(living_mob)
		return

	var/obj/structure/closet/supplypod/centcompod/toLaunch = new()
	living_mob.forceMove(toLaunch)
	new /obj/effect/pod_landingzone(spawn_turf, toLaunch)

///////////////////////////////////
//Keeps track of all living heads//
///////////////////////////////////
/datum/controller/subsystem/job/proc/get_living_heads()
	. = list()
	for(var/mob/living/carbon/human/player in GLOB.alive_mob_list)
		if(player.stat != DEAD && player.mind && (player.mind.assigned_role in SSdepartment.get_jobs_by_dept_id(DEPT_NAME_COMMAND)))
			. |= player.mind


////////////////////////////
//Keeps track of all heads//
////////////////////////////
/datum/controller/subsystem/job/proc/get_all_heads()
	. = list()
	for(var/i in GLOB.mob_list)
		var/mob/player = i
		if(player.mind && (player.mind.assigned_role in SSdepartment.get_jobs_by_dept_id(DEPT_NAME_COMMAND)))
			. |= player.mind

//////////////////////////////////////////////
//Keeps track of all living security members//
//////////////////////////////////////////////
/datum/controller/subsystem/job/proc/get_living_sec()
	. = list()
	for(var/mob/living/carbon/human/player in GLOB.carbon_list)
		if(player.stat != DEAD && player.mind && (player.mind.assigned_role in SSdepartment.get_jobs_by_dept_id(DEPT_NAME_SECURITY)))
			. |= player.mind

////////////////////////////////////////
//Keeps track of all  security members//
////////////////////////////////////////
/datum/controller/subsystem/job/proc/get_all_sec()
	. = list()
	for(var/mob/living/carbon/human/player in GLOB.carbon_list)
		if(player.mind && (player.mind.assigned_role in SSdepartment.get_jobs_by_dept_id(DEPT_NAME_SECURITY)))
			. |= player.mind

/datum/controller/subsystem/job/proc/JobDebug(message)
	log_job_debug(message)

/obj/item/paper/fluff/spare_id_safe_code
	name = "Nanotrasen-Approved Spare ID Safe Code"
	desc = "Proof that you have been approved for Captaincy, with all its glory and all its horror."

/obj/item/paper/fluff/spare_id_safe_code/Initialize(mapload)
	var/id_safe_code = SSjob.spare_id_safe_code
	default_raw_text = "Captain's Spare ID safe code combination: [id_safe_code ? id_safe_code : "\[REDACTED\]"]<br><br>The spare ID can be found in its dedicated safe on the bridge."
	return ..()

/obj/item/paper/fluff/spare_id_safe_code/emergency_spare_id_safe_code
	name = "Emergency Spare ID Safe Code Requisition"
	desc = "Proof that nobody has been approved for Captaincy. A skeleton key for a skeleton shift."

/datum/controller/subsystem/job/proc/promote_to_captain(var/mob/dead/new_player/authenticated/new_captain, acting_captain = FALSE)
	var/mob/living/carbon/human/H = new_captain.new_character
	if(!new_captain)
		CRASH("Cannot promote [new_captain.ckey], there is no new_character attached to him.")

	if(!spare_id_safe_code)
		CRASH("Cannot promote [H.real_name] to Captain, there is no spare_id_safe_code.")

	var/paper = new /obj/item/paper/fluff/spare_id_safe_code(H.loc)
	var/list/slots = list(
		"in your left pocket" = ITEM_SLOT_LPOCKET,
		"in your right pocket" = ITEM_SLOT_RPOCKET,
		"in your backpack" = ITEM_SLOT_BACKPACK,
		"in your hands" = ITEM_SLOT_HANDS
	)
	var/where = H.equip_in_one_of_slots(paper, slots, FALSE) || "at your feet"

	if(acting_captain)
		to_chat(new_captain, span_notice("Due to your position in the chain of command, you have been granted access to captain's spare ID. You can find in important note about this [where]."))
	else
		to_chat(new_captain, span_notice("You can find the code to obtain your spare ID from the secure safe on the Bridge [where]."))

	// Force-give their ID card bridge access.
	if(H.wear_id?.GetID())
		var/obj/item/card/id/id_card = H.wear_id
		if(!(ACCESS_HEADS in id_card.access))
			LAZYADD(id_card.access, ACCESS_HEADS)

	assigned_captain = TRUE

/// Send a drop pod containing a piece of paper with the spare ID safe code to loc
/datum/controller/subsystem/job/proc/send_spare_id_safe_code(loc)
	new /obj/effect/pod_landingzone(loc, /obj/structure/closet/supplypod/centcompod, new /obj/item/paper/fluff/spare_id_safe_code/emergency_spare_id_safe_code())
	safe_code_timer_id = null
	safe_code_request_loc = null
