#!/usr/bin/env node

/*
  This node.js script is required in order to patch package-lock.json with new sha512 hashes.
  Sadly this can't be done with Nix due to restricted evaluation mode.
  This script should not have any external npm dependencies
*/

import fs from "fs"

import { loadJSONFile, loadAllPackageLocks, getHashOf } from "./lib.mjs"

const updateDependencies = async (snapshot, dependencies) => {
	let result = {};

	for (const packageName in dependencies) {
		const version = dependencies[packageName].version;
		result[packageName] = { ...dependencies[packageName] };
		 try {
			const hashType = dependencies[packageName].integrity.split("-")[0];
			result[packageName].integrity = await getHashOf(hashType, snapshot[packageName][version]);

			if (result[packageName].integrity !== dependencies[packageName].integrity)
				console.log(`[lock-patcher] ${packageName}-${version}: ${dependencies[packageName].integrity} -> ${result[packageName].integrity}`);
		}
		 catch (err) {
			console.error(`[lock-patcher] At: ${packageName}-${version} (${JSON.stringify(snapshot[packageName])})`);
			console.error(err);
		}

		if (dependencies[packageName].dependencies) {
			result[packageName].dependencies = await updateDependencies(snapshot, dependencies[packageName].dependencies);
		};
	}

	return result;
};

(async () => {
	if (process.argv.length != 3) {
		console.log("Usage:");
		console.log(`    ${process.argv[0]} ${process.argv[1]} [snapshot]}`);

	    process.exit(-1);
	};

	console.log("[lock-patcher] Loading Snapshot ...");
	const snapshot = await loadJSONFile(process.argv[2]);

	console.log(`[lock-patcher] Looking for package locks (in ${process.cwd()}) ...`)
	const foundPackageLocks = await loadAllPackageLocks(process.cwd());
	console.log(`[lock-patcher] Found: ${foundPackageLocks}`);

	const packageLocks = [];
	console.log("[lock-patcher] Loading package-locks ...");

	for (const lock of foundPackageLocks) {
		try {
			packageLocks.push({
				parsed: await loadJSONFile(lock),
				path: lock
			});
		}
		catch (err) {
			console.error(`[lock-patcher] Could not load: ${lock}`);
			console.error(err);
		}
	}

	console.log("[lock-patcher] Patching locks ...");

	packageLocks.forEach(async (lock) => {
		lock.parsed.dependencies = await updateDependencies(snapshot, lock.parsed.dependencies);
		fs.writeFileSync(lock.path, JSON.stringify(lock.parsed), {encoding:'utf8',flag:'w'});
	});
})().catch((err) => {
    console.error("[lock-patcher] Error:");
    console.error(err);
});
