# This file is a part of Julia. License is MIT: https://julialang.org/license

# Advisory reentrant lock
"""
    ReentrantLock()

Creates a re-entrant lock for synchronizing [`Task`](@ref)s.
The same task can acquire the lock as many times as required.
Each [`lock`](@ref) must be matched with an [`unlock`](@ref).

This lock is NOT thread-safe. See [`Threads.ReentrantLockMT`](@ref) for a thread-safe version.
"""
mutable struct GenericReentrantLock{ThreadLock<:AbstractLock} <: AbstractLock
    locked_by::Union{Task, Nothing}
    cond_wait::GenericCondition{ThreadLock}
    reentrancy_cnt::Int

    GenericReentrantLock{ThreadLock}() where {ThreadLock<:AbstractLock} = new(nothing, GenericCondition{ThreadLock}(), 0)
end

# A basic single-threaded, Julia-aware lock:
const ReentrantLock = GenericReentrantLock{CooperativeLock}


"""
    islocked(lock) -> Status (Boolean)

Check whether the `lock` is held by any task/thread.
This should not be used for synchronization (see instead [`trylock`](@ref)).
"""
function islocked(rl::GenericReentrantLock)
    return rl.reentrancy_cnt != 0
end

"""
    trylock(lock) -> Success (Boolean)

Acquire the lock if it is available,
and return `true` if successful.
If the lock is already locked by a different task/thread,
return `false`.

Each successful `trylock` must be matched by an [`unlock`](@ref).
"""
function trylock(rl::GenericReentrantLock)
    t = current_task()
    lock(rl.cond_wait)
    try
        if rl.reentrancy_cnt == 0
            rl.locked_by = t
            rl.reentrancy_cnt = 1
            return true
        elseif t == notnothing(rl.locked_by)
            rl.reentrancy_cnt += 1
            return true
        end
        return false
    finally
        unlock(rl.cond_wait)
    end
end

"""
    lock(lock)

Acquire the `lock` when it becomes available.
If the lock is already locked by a different task/thread,
wait for it to become available.

Each `lock` must be matched by an [`unlock`](@ref).
"""
function lock(rl::GenericReentrantLock)
    t = current_task()
    lock(rl.cond_wait)
    try
        while true
            if rl.reentrancy_cnt == 0
                rl.locked_by = t
                rl.reentrancy_cnt = 1
                return
            elseif t == notnothing(rl.locked_by)
                rl.reentrancy_cnt += 1
                return
            end
            wait(rl.cond_wait)
        end
    finally
        unlock(rl.cond_wait)
    end
end

"""
    unlock(lock)

Releases ownership of the `lock`.

If this is a recursive lock which has been acquired before, decrement an
internal counter and return immediately.
"""
function unlock(rl::GenericReentrantLock)
    t = current_task()
    rl.reentrancy_cnt == 0 && error("unlock count must match lock count")
    rl.locked_by == t || error("unlock from wrong thread")
    lock(rl.cond_wait)
    try
        rl.reentrancy_cnt -= 1
        if rl.reentrancy_cnt == 0
            rl.locked_by = nothing
            notify(rl.cond_wait)
        end
    finally
        unlock(rl.cond_wait)
    end
    return
end

function lock(f, l::AbstractLock)
    lock(l)
    try
        return f()
    finally
        unlock(l)
    end
end

function trylock(f, l::AbstractLock)
    if trylock(l)
        try
            return f()
        finally
            unlock(l)
        end
    end
    return false
end

"""
    Semaphore(sem_size)

Create a counting semaphore that allows at most `sem_size`
acquires to be in use at any time.
Each acquire must be matched with a release.

This construct is NOT threadsafe.
"""
mutable struct Semaphore
    sem_size::Int
    curr_cnt::Int
    cond_wait::Condition
    Semaphore(sem_size) = sem_size > 0 ? new(sem_size, 0, Condition()) : throw(ArgumentError("Semaphore size must be > 0"))
end

"""
    acquire(s::Semaphore)

Wait for one of the `sem_size` permits to be available,
blocking until one can be acquired.
"""
function acquire(s::Semaphore)
    while true
        if s.curr_cnt < s.sem_size
            s.curr_cnt = s.curr_cnt + 1
            return
        else
            wait(s.cond_wait)
        end
    end
end

"""
    release(s::Semaphore)

Return one permit to the pool,
possibly allowing another task to acquire it
and resume execution.
"""
function release(s::Semaphore)
    @assert s.curr_cnt > 0 "release count must match acquire count"
    s.curr_cnt -= 1
    notify(s.cond_wait; all=false)
    return
end
