#!/usr/bin/env node

/*
  This node.js script is required in order to patch package-lock.json with new sha512 hashes.

  It loads all `package-lock.json` files that are in root of the project as well as these
  nested inside folders and patches their integrity based on packages snapshot created by Nix.

  Sadly this can't be done with Nix due to restricted evaluation mode.
  This script should not have any external npm dependencies
*/

import fsPromises from "fs/promises"

import { loadJSONFile, loadAllPackageLocks, getHashOf } from "./lib.mjs"

// Returns new set, that is modified dependencies argument
// with proper integrity hashes
const updateDependencies = async (snapshot, dependencies) => Object.fromEntries(
	await Promise.all(Object.entries(dependencies).map(async ([packageName, pkg]) => {
		try {
			const hashType = pkg.integrity ? pkg.integrity.split("-")[0] : undefined;
			return [
				packageName,
				{
					...pkg,
					integrity: hashType ? await getHashOf(hashType, snapshot[packageName][pkg.version]) : undefined,
					dependencies: pkg.dependencies ? await updateDependencies(snapshot, pkg.dependencies) : undefined
				}
			]
		}
		catch (err) {
			console.error(`[lock-patcher] At: ${packageName}-${pkg.version} (${JSON.stringify(snapshot[packageName])})`);
			console.error(err);
			return [packageName, pkg];
		}
	}))
);

// Returns new set, that is modified packages argument
// with proper integrity hashes
const packageNameRegex = /node_modules\/(?<name>(?:@[^/]+\/)?[^/]+)$/;
const updatePackages = async (snapshot, packages) => Object.fromEntries(
	await Promise.all(Object.entries(packages).map(async ([packagePath, pkg]) => {
		const packageName = packagePath.match(packageNameRegex)?.groups.name;
		try {
			const hashType = pkg.integrity ? pkg.integrity.split("-")[0] : undefined;
			return [
				packagePath,
				{
					...pkg,
					integrity: hashType ? await getHashOf(hashType, snapshot[packageName][pkg.version]) : undefined,
				}
			]
		}
		catch (err) {
			console.error(`[lock-patcher] At: ${packageName}-${pkg.version} (${JSON.stringify(snapshot[packageName])})`);
			console.error(err);
			return [packagePath, pkg];
		}
	}))
);

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
	const packageLocks = await Promise.all(
		foundPackageLocks.map((lock) => loadJSONFile(lock)
			.then(parsed => ({ parsed: parsed, path: lock }))
			.catch((err) => {
				console.error(`[lock-patcher] Could not load: ${lock}`);
				console.error(err);
				return null;
			}))
	).then(locks => locks.filter(val => val != null));

	console.log("[lock-patcher] Patching locks ...");

	const promises = packageLocks.map(async (lock) => {
		const set = {
			...lock.parsed,
			// lockfileVersion ≤ 2
			dependencies: lock.parsed.dependencies ? await updateDependencies(snapshot, lock.parsed.dependencies) : undefined,
			// lockfileVersion ≥ 2
			packages: lock.parsed.packages ? await updatePackages(snapshot, lock.parsed.packages) : undefined,
		};

		return await fsPromises.writeFile(lock.path, JSON.stringify(set), { encoding: 'utf8', flag: 'w' });
	});

	await Promise.all(promises);
})().catch((err) => {
	console.error("[lock-patcher] Error:");
	console.error(err);
});
