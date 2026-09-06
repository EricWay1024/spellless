-- What build is actually running.
--
-- This file is deliberately the *only* place the answer lives, and
-- scripts/install.py overwrites it in the deployed copy with the real values.
-- That placement is the whole point.
--
-- The failure this exists to catch is not "the files on disk are old" -- they
-- rarely are, because the installer just wrote them.  It is "Rime is still
-- running the code it loaded twenty minutes ago", which looks identical from
-- outside and has cost hours of testing a build that was not there.  A stamp
-- read from a data file would be re-read and would report the fresh value
-- while the stale code ran.  A stamp compiled into a module reports whatever
-- the running process actually loaded, which is the question being asked.
--
-- The copy in the repository says "source" because that is true: the tests and
-- benchmarks run against the working tree, and there is no build to identify.

return {
  revision  = "source",
  built     = nil,
  installed = nil,
}
