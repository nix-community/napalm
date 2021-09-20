#!/usr/bin/env node

/*
  This node.js script is required in order to patch package-lock.json with new sha512 hashes.

  It loads all `package-lock.json` files that are in root of the project as well as these
  nested inside folders and patches their integrity based on packages snapshot created by Nix.

  Sadly this can't be done with Nix due to restricted evaluation mode.
  This script should not have any external npm dependencies
*/

import fsPromises from "fs/promises"

import { loadJSONFile, loadAllPackageLocks, getHashOf, mapOverAttrsAsync } from "./lib.mjs"

// Returns new set, that is modified dependencies argument
// with proper integirty hashes
const updateDependencies = (snapshot, dependencies) => mapOverAttrsAsync(async (packageName, pkg) => {
	const hashType = pkg.integrity.split("-")[0];

	try {
		if (pkg.dependencies) {
			return {
				...pkg,
				integrity: await getHashOf(hashType, snapshot[packageName][pkg.version]),
				dependencies: await updateDependencies(snapshot, pkg.dependencies)
			};
		}
		else {
			return {
				...pkg,
				integrity: await getHashOf(hashType, snapshot[packageName][pkg.version])
			};
		}
	}
	catch (err) {
		console.error(`[lock-patcher] At: ${packageName}-${pkg.version} (${JSON.stringify(snapshot[packageName])})`);
		console.error(err);
		return pkg;
	}
}, dependencies);

(async () => {
	if (process.argv.length != 3) {
		console.log("Usage:");
		console.log(`    ${process.argv[0]} ${process.argv[1]} [snapshot]`);

		process.exit(-1);
	};

	console.log("[lock-patcher] Loading Snapshot ...");
	const snapshot = await loadJSONFile(process.argv[2]);

	console.log(`[lock-patcher] Looking for package locks (in ${process.cwd()}) ...`)
	const foundPackageLocks = await loadAllPackageLocks(process.cwd());
	console.log(`[lock-patcher] Found: ${foundPackageLocks}`);

	console.log("[lock-patcher] Loading package-locks ...");
	const packageLocks = (await Promise.all(
		foundPackageLocks.map(async (lock) => {
			try {
				return {
					parsed: await loadJSONFile(lock),
					path: lock
				};
			}
			catch (err) {
				console.error(`[lock-patcher] Could not load: ${lock}`);
				console.error(err);
				return null;
			}
		}))).filter(val => val != null);

	console.log("[lock-patcher] Patching locks ...");

	packageLocks.forEach(async (lock) => {
		const set = {
			...lock.parsed,
			dependencies: await updateDependencies(snapshot, lock.parsed.dependencies)
		};

		await fsPromises.writeFile(lock.path, JSON.stringify(set), { encoding: 'utf8', flag: 'w' });
	});
})().catch((err) => {
	console.error("[lock-patcher] Error:");
	console.error(err);
});
