// Headless Ghidra script: decompile every function in the program and write
// one .c file per binary, plus a symbol index. Used to recover the parts of
// IW2 that live only in the engine binaries (HUD presentation, flight/LDS
// constants, subsim rules) — everything that isn't in the resource files.
//
// Run via: analyzeHeadless <proj> <name> -import <bin> -postScript ExportDecomp.java <outdir>
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

import java.io.File;
import java.io.PrintWriter;

public class ExportDecomp extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outDir = args.length > 0 ? args[0] : ".";
        new File(outDir).mkdirs();
        String base = currentProgram.getName().replaceAll("[^A-Za-z0-9_.-]", "_");

        DecompInterface dec = new DecompInterface();
        dec.openProgram(currentProgram);

        PrintWriter c = new PrintWriter(new File(outDir, base + ".c"), "UTF-8");
        PrintWriter idx = new PrintWriter(new File(outDir, base + ".symbols.txt"), "UTF-8");

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        int n = 0, ok = 0;
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            n++;
            idx.printf("%s\t%s\t%d%n", f.getEntryPoint(), f.getName(),
                    f.getBody().getNumAddresses());
            DecompileResults res = dec.decompileFunction(f, 60, monitor);
            if (res != null && res.decompileCompleted()) {
                c.printf("// ==== %s @ %s ====%n", f.getName(), f.getEntryPoint());
                c.println(res.getDecompiledFunction().getC());
                ok++;
            }
            if (n % 250 == 0) {
                println("decompiled " + ok + "/" + n);
            }
        }
        c.close();
        idx.close();
        dec.dispose();
        println("DONE " + base + ": " + ok + "/" + n + " functions -> " + outDir);
    }
}
