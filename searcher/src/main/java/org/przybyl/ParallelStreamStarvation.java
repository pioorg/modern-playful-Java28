package org.przybyl;

import java.util.concurrent.ForkJoinPool;
import java.util.stream.IntStream;

/**
 * Demonstrates how two parallel streams compete for the common pool.
 *
 * Without competition, TASK's elements can run concurrently.
 * With BUSY-NEIGHBOUR running, TASK may initially run only on main.
 * Pool workers can help TASK when they finish their current work,
 * but they may process more BUSY-NEIGHBOUR elements before doing so.
 *
 * Compare TASK's start times, thread names, and total elapsed time.
 * Scheduling is timing-dependent; this is a demo, not a benchmark.
 */
public class ParallelStreamStarvation {

    public static void main(String[] args) throws InterruptedException {
        // Run once with false, then again with true.
        boolean startBusyNeighbour = false;

        int taskDurationMillis = 10_000;
        int processors = Runtime.getRuntime().availableProcessors();
        int workers = ForkJoinPool.getCommonPoolParallelism();
        int taskElements = Math.max(2, processors / 2);

        System.out.printf("""
                Available processors: %d
                Common pool target parallelism: %d
                Busy neighbour enabled: %s

                TASK has %d elements, each keeping a thread busy for %.1f seconds.
                If they all start together, they should finish in about %.1f seconds.

                Watch the TASK START timestamps:
                close together = concurrent starts; spread apart = delayed starts.
                Timestamps below are seconds since the demo started.

                """,
            processors, workers, startBusyNeighbour,
            taskElements,
            taskDurationMillis / 1_000.0,
            taskDurationMillis / 1_000.0);

        long demoStart = System.nanoTime();

        if (startBusyNeighbour) {
            // Submit enough work to keep the common pool busy.
            Thread busyNeighbour = new Thread(
                () -> IntStream.range(0, 2 * (workers + 1))
                    .parallel()
                    .forEach(i -> runTask(
                        "BUSY-NEIGHBOUR", i, taskDurationMillis, demoStart)),
                "busy-neighbour-caller"
            );

            // Allow the demo to exit once TASK finishes.
            busyNeighbour.setDaemon(true);
            busyNeighbour.start();

            // Give BUSY-NEIGHBOUR a head start.
            // This does not guarantee saturation.
            Thread.sleep(200);
        }

        System.out.println("\n--- Starting TASK ---");
        long taskStart = System.nanoTime();

        IntStream.range(0, taskElements)
            .parallel()
            .forEach(i -> runTask(
                "TASK", i, taskDurationMillis, demoStart));

        double elapsedSeconds =
            (System.nanoTime() - taskStart) / 1_000_000_000.0;

        System.out.printf("""
                
                --- TASK finished in %.1f seconds ---
                Each element kept its thread busy for about %.1f seconds.
                If TASK took longer, check how late its last elements started.
                Compare with startBusyNeighbour = %s.

                TASK and BUSY-NEIGHBOUR share the common pool.
                parallel() does not reserve workers for TASK.
                %n""",
            elapsedSeconds,
            taskDurationMillis / 1_000.0,
            !startBusyNeighbour);
    }

    private static void runTask(
        String stream, int element, int durationMillis, long demoStart) {

        log(demoStart, stream, element, "START");
        keepBusy(durationMillis);
        log(demoStart, stream, element, "END");
    }

    private static void log(
        long demoStart, String stream, int element, String phase) {

        double elapsedSeconds =
            (System.nanoTime() - demoStart) / 1_000_000_000.0;

        System.out.printf("+%6.1f s  %-14s %02d %-5s on %s%n",
            elapsedSeconds, stream, element, phase,
            Thread.currentThread().getName());
    }

    private static void keepBusy(int durationMillis) {
        long start = System.nanoTime();
        long durationNanos = durationMillis * 1_000_000L;

        // Deliberately occupy the executing thread without sleeping.
        while (System.nanoTime() - start < durationNanos) {
            Thread.onSpinWait();
        }
    }
}