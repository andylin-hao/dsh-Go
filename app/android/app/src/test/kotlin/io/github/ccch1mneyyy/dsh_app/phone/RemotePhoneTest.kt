package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Agents on computers (dsh-go-link): who owns a task, who is turned away, and the relay's dispatch. */
class RemotePhoneTest {
    private var now = 1_000_000L
    private fun tasks() = PhoneTasks(clock = { now })
    private val claude = PhoneOrigin.of("ssh:h1/m1", "claude-code", "dev-box")
    private val codex = PhoneOrigin.of("ssh:h1/m2", "codex-mcp-client", "dev-box")

    private fun refusal(b: PhoneTasks.Begin): String? = (b as? PhoneTasks.Begin.Refused)?.message

    @Test fun anAgentOwnsTheTaskItStartsAndOthersAreBusy() {
        val t = tasks()
        assertTrue(t.begin(claude) is PhoneTasks.Begin.Go)
        assertEquals(claude, t.snapshot().origin)
        assertEquals(claude, t.activeOrigin())
        assertEquals(mapOf("key" to "ssh:h1/m1", "client" to "claude-code", "host" to "dev-box", "label" to "Claude Code · dev-box"),
            t.snapshot().toMap()["origin"])

        val local = refusal(t.begin())!!
        assertTrue(local, local.startsWith("[PHONE_BUSY]"))
        assertTrue(local, local.contains("Claude Code · dev-box"))
        val other = refusal(t.begin(codex))!!
        assertTrue(other.startsWith("[PHONE_BUSY]"))
        // The owner goes on.
        assertTrue(t.begin(claude) is PhoneTasks.Begin.Go)
    }

    @Test fun thisPhonesEngineIsNamedWhenItIsTheOwner() {
        val t = tasks()
        t.begin()
        assertNull(t.snapshot().origin)
        assertNull(t.activeOrigin())
        val r = t.refusalFor(claude)!!
        assertTrue(r, r.contains("这台手机上的 DSH"))
        assertNull(t.refusalFor(null))
    }

    @Test fun refusedCallsNeverKeepTheOwnersTaskAlive() {
        val t = tasks()
        t.callStarted()
        t.begin()
        t.callEnded()
        // A busy agent retries for longer than the idle limit: the engine's task still idles out.
        repeat(8) {
            now += 30_000
            t.callStarted()
            assertTrue(refusal(t.begin(claude)) != null || t.snapshot().origin == claude)
            t.touch(claude)
            t.callEnded(claude)
        }
        now += 1
        assertTrue(t.begin(claude) is PhoneTasks.Begin.Go)
        assertEquals(claude, t.snapshot().origin)
    }

    @Test fun onlyTheStoppedOwnersRetriesExtendTheHold() {
        val t = tasks()
        t.begin(claude)
        t.stop("用户停止")
        val s = t.snapshot()
        assertTrue(s.stopped)
        assertEquals(claude, s.origin)

        now += 20_000
        assertTrue(refusal(t.begin(claude))!!.startsWith(PhoneTasks.STOPPED_MESSAGE))
        // Someone else is told the person just stopped, without extending the hold.
        now += 20_000
        assertEquals(PhoneTasks.JUST_STOPPED_MESSAGE, refusal(t.begin()))
        assertEquals(PhoneTasks.JUST_STOPPED_MESSAGE, t.refusalFor(codex))
        // 30 s after the owner's last retry the phone is free again.
        now += 10_001
        assertTrue(t.begin() is PhoneTasks.Begin.Go)
        assertNull(t.snapshot().origin)
    }

    @Test fun thePreCheckLeavesTheStoppedOwnersRetriesToBeginWhichExtendsTheHold() {
        val t = tasks()
        t.begin()
        t.stop("用户停止")
        repeat(4) {
            now += 20_000
            // PhoneCore asks first; the engine's own retry goes on to begin, refused there (and logged).
            assertNull(t.refusalFor(null))
            assertTrue(refusal(t.begin())!!.startsWith(PhoneTasks.STOPPED_MESSAGE))
        }
        now += 30_001
        assertNull(t.refusalFor(null))
        assertTrue(t.begin() is PhoneTasks.Begin.Go)
    }

    @Test fun thePreCheckChangesNothing() {
        val t = tasks()
        t.begin(claude)
        now += PhoneTasks().idleMs + 1
        // Idle: left for begin to end, so the next owner can start.
        assertNull(t.refusalFor(null))
        assertTrue(t.snapshot().origin == null)
        assertTrue(t.begin() is PhoneTasks.Begin.Go)
        assertNull(t.snapshot().origin)
    }

    @Test fun anAgentsTurnEndFinishesOnlyItsOwnTaskOrHold() {
        val t = tasks()
        t.begin(claude)
        assertFalse(t.finishOwnedBy(codex.key))
        t.callStarted()
        assertFalse(t.finishOwnedBy(claude.key))
        t.callEnded(claude)
        assertTrue(t.finishOwnedBy(claude.key))
        assertFalse(t.snapshot().active)
        // A stop's hold on that agent goes with its turn: its next turn may start.
        t.begin(claude)
        t.stop("用户停止")
        assertTrue(t.finishOwnedBy(claude.key))
        assertFalse(t.snapshot().stopped)
        assertTrue(t.begin(claude) is PhoneTasks.Begin.Go)
        assertFalse(t.finishOwnedBy("nobody"))
    }

    @Test fun aStopWithNothingRunningBelongsToTheLastOwner() {
        val t = tasks()
        t.begin(claude)
        assertTrue(t.finish())
        t.stop("用户在 App 里停止")
        assertEquals(claude, t.snapshot().origin)
        assertEquals(PhoneTasks.JUST_STOPPED_MESSAGE, refusal(t.begin()))
    }

    @Test fun onlyAStopThePersonAskedForSaysSo() {
        // Screen off or the service going away: the phone task ends, a computer agent's turn goes on.
        val t = tasks()
        t.begin(claude)
        t.stop("屏幕关闭了")
        assertTrue(t.snapshot().stopped)
        assertFalse(t.snapshot().stoppedByPerson)
        assertEquals(false, t.snapshot().toMap()["stoppedByPerson"])
        // 停止 on the bar or in the app: the agent's turn stops too.
        now += PhoneTasks().stopHoldMs + 1
        t.begin(claude)
        t.stop("你在悬浮条上点了停止", byPerson = true)
        assertTrue(t.snapshot().stoppedByPerson)
        assertEquals(true, t.snapshot().toMap()["stoppedByPerson"])
        // Once the hold is over, nothing is stopped any more.
        now += PhoneTasks().stopHoldMs + 1
        assertFalse(t.snapshot().stoppedByPerson)
    }

    @Test fun theOwnersAgentLeavingEndsItsTaskButNotAnothers() {
        val t = tasks()
        t.begin(claude)
        t.endIfOwner(codex)
        assertTrue(t.snapshot().active)
        t.callStarted()
        t.endIfOwner(claude)
        // A call of it still runs: not now.
        assertTrue(t.snapshot().active)
        t.callEnded(claude)
        t.endIfOwner(claude)
        val s = t.snapshot()
        assertFalse(s.active)
        assertFalse(s.stopped)
        assertTrue(t.begin(codex) is PhoneTasks.Begin.Go)
    }

    @Test fun labelsComeCleanAndShort() {
        assertEquals("Codex · dev-box", codex.label)
        assertEquals("my-agent · box", PhoneOrigin.of("k", "my-agent", "box").label)
        val tricky = PhoneOrigin.of("k", "Claude\nCode‮", "a\u0000b")
        assertEquals("Claude Code", tricky.client)
        assertEquals("a b", tricky.host)
        val long = PhoneOrigin.of("k", "x".repeat(100), "")
        assertEquals(40, long.client!!.length)
        assertTrue(long.client!!.endsWith("…"))
        assertEquals("?", long.host)
        assertNull(PhoneOrigin.of("k", "  ", "h").client)
    }

    @Test fun theActionLogKeepsWhoMadeEachCall() {
        val log = ActionLog(clock = { now })
        log.add("tap", "微信", "点「发送」", "ok", claude.label)
        log.add("screen", null, "读屏", "ok")
        val maps = log.toMaps(10)
        assertNull(maps[0]["origin"])
        assertEquals("Claude Code · dev-box", maps[1]["origin"])
    }

    @Test fun channelsRunToolCallsWithTheirOriginAndAnswerTheRest() {
        val seen = mutableListOf<Pair<String, PhoneOrigin>>()
        val closed = mutableListOf<PhoneOrigin>()
        val sessions = RemotePhoneSessions({ name, _, origin -> seen += name to origin; ToolOutput("done") }, "1") { closed += it }
        sessions.open("m1", claude)
        sessions.open("m2", codex)
        assertEquals(2, sessions.size)

        val latch = CountDownLatch(1)
        var answer: String? = null
        sessions.line("m2", """{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"screen","arguments":{}}}""") {
            answer = it
            latch.countDown()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("screen" to codex), seen)
        val reply = Json.parse(answer!!) as Map<*, *>
        assertEquals(7L, (reply["id"] as Number).toLong())
        assertEquals(false, (reply["result"] as Map<*, *>)["isError"])

        var ping: String? = "unset"
        sessions.line("m1", """{"jsonrpc":"2.0","id":1,"method":"ping"}""") { ping = it }
        assertEquals("""{"jsonrpc":"2.0","id":1,"result":{}}""", ping)
        var none: String? = "unset"
        sessions.line("m1", """{"jsonrpc":"2.0","method":"notifications/cancelled"}""") { none = it }
        assertNull(none)
        var unknown: String? = "unset"
        sessions.line("m9", """{"jsonrpc":"2.0","id":1,"method":"ping"}""") { unknown = it }
        assertNull(unknown)

        sessions.close("m1")
        assertEquals(listOf(claude), closed)
        sessions.closeAll()
        assertEquals(listOf(claude, codex), closed)
        assertEquals(0, sessions.size)
    }

    @Test fun theCatalogForAgentsIsTheFixedOneWithInstructions() {
        val c = RemotePhoneSessions.catalog("1")
        assertEquals(PhoneToolCatalog.listJson(), c["tools"])
        assertTrue((c["instructions"] as String).contains("handoff"))
        assertEquals(mapOf("name" to "dsh-app-phone", "version" to "1"), c["serverInfo"])
    }
}
