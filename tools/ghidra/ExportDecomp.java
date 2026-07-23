// Headless Ghidra script: decompile every function in the program and write
// one .c file per binary, plus a symbol index. Used to recover the parts of
// IW2 that live only in the engine binaries (HUD presentation, flight/LDS
// constants, subsim rules) — everything that isn't in the resource files.
//
// Run via: analyzeHeadless <proj> <name> -import <bin>
//              -postScript ExportDecomp.java <outdir> [knowledgeDir]
//
// KNOWLEDGE LAYER (arg 1, optional). The raw Ghidra pass is lossy: it silently
// drops functions whose boundaries it cannot recover, and it prints
// *(undefined4*)(this+0x1e4) where a named struct field belongs. Rather than
// hand-edit the throwaway .c, we feed our accumulated analysis back IN, so each
// regeneration is strictly better. Before decompiling we apply, per binary,
// from <knowledgeDir>/<binaryName>/:
//   functions.tsv  VA[\tname]   -- force-create a function at VA (recovers a
//                                  dropped body); optionally name it.
//   names.tsv      VA\tname     -- rename the function/symbol at VA.
// (types.h / signatures are the next layer -- see the knowledge repo README.)
// The knowledge lives in a SEPARATE repo (build/ghidra-knowledge/), never in
// iw2-remaster: it is a map of the copyrighted binary, like the decomp itself.
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.SourceType;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;

public class ExportDecomp extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outDir = args.length > 0 ? args[0] : ".";
        String knowDir = args.length > 1 ? args[1] : null;
        new File(outDir).mkdirs();
        String base = currentProgram.getName().replaceAll("[^A-Za-z0-9_.-]", "_");

        applyKnowledge(knowDir, currentProgram.getName());

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

    // Apply the git-tracked knowledge layer for this binary before decompiling.
    private void applyKnowledge(String knowDir, String binName) {
        if (knowDir == null) {
            return;
        }
        File binDir = new File(knowDir, binName);
        if (!binDir.isDirectory()) {
            println("knowledge: none for " + binName + " (" + binDir + ")");
            return;
        }
        int made = applyFunctions(new File(binDir, "functions.tsv"));
        int named = applyNames(new File(binDir, "names.tsv"));
        println("knowledge " + binName + ": +" + made + " functions, " + named + " renames");
    }

    // functions.tsv: force-create a function at each VA (recovering a dropped
    // body), optionally naming it. Verified on the next pass when the .c shows
    // a real body at that address.
    private int applyFunctions(File f) {
        int made = 0;
        for (String[] row : readTsv(f)) {
            try {
                Address a = toAddr(Long.decode(row[0]));
                String name = row.length > 1 ? row[1] : null;
                Function fn = getFunctionAt(a);
                if (fn == null) {
                    disassemble(a);
                    fn = createFunction(a, (name == null || name.isEmpty()) ? null : name);
                    if (fn != null) {
                        made++;
                    } else {
                        println("knowledge functions: could not create at " + row[0]);
                    }
                } else if (name != null && !name.isEmpty()) {
                    fn.setName(name, SourceType.USER_DEFINED);
                }
            } catch (Exception e) {
                println("knowledge functions: " + row[0] + " -> " + e);
            }
        }
        return made;
    }

    // names.tsv: rename the function (or drop a label) at each VA.
    private int applyNames(File f) {
        int named = 0;
        for (String[] row : readTsv(f)) {
            if (row.length < 2) {
                continue;
            }
            try {
                Address a = toAddr(Long.decode(row[0]));
                Function fn = getFunctionAt(a);
                if (fn != null) {
                    fn.setName(row[1], SourceType.USER_DEFINED);
                } else {
                    createLabel(a, row[1], true, SourceType.USER_DEFINED);
                }
                named++;
            } catch (Exception e) {
                println("knowledge names: " + row[0] + " -> " + e);
            }
        }
        return named;
    }

    // Tab-separated rows; blank lines and '#' comments ignored.
    private List<String[]> readTsv(File f) {
        List<String[]> rows = new ArrayList<String[]>();
        if (f == null || !f.isFile()) {
            return rows;
        }
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) {
                String s = line.trim();
                if (s.isEmpty() || s.charAt(0) == '#') {
                    continue;
                }
                rows.add(s.split("\t"));
            }
        } catch (Exception e) {
            println("knowledge: cannot read " + f + " -> " + e);
        }
        return rows;
    }
}
