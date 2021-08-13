#!/usr/bin/env node

/*
  This node.js script is required in order to patch package-lock.json with new sha512 hashes.
  Sadly this can't be done with Nix due to restricted evaluation mode.
  This script should not have any external npm dependencies
*/

const fs = require("fs");
const crypto = require("crypto");

const loadAllPackageLocks = async (root) => {
	const files = fs.readdirSync(root, { withFileTypes: true });
	let locks = [];

	for (const file of files) {
		const fileName = `${root}/${file.name}`;

		if (file.isDirectory()) {
			const additionalLocks = await loadAllPackageLocks(fileName);
			locks = locks.concat(additionalLocks);
		}

		if (file.name === "package-lock.json")
			locks.push(fileName);
	}
	return locks;
};

const loadJSONFile = (file) => {
	return new Promise((resolve, reject) => {
		fs.readFile(file, 'utf8', (err, data) => {
			if (err) reject(err);

			const parsed = JSON.parse(data);

			resolve(parsed);
		});
	});
};

const getHashOf = (type, file) => {
	return new Promise((resolve, reject) => {
		const fd = fs.createReadStream(file);
		const hash = crypto.createHash(type);

		hash.setEncoding("hex");

		fd.on("end", () => {
			hash.end();
			resolve(`${type}-${hash.digest('base64')}`);
		});

		fd.on("error", reject);

		fd.pipe(hash);
	});
};

const updateDependencies = async (snapshot, dependencies) => {
	let result = {};

	for (const packageName in dependencies) {
		const version = dependencies[packageName].version;
		result[packageName] = { ...dependencies[packageName] };
		 try {
			const hashType = dependencies[packageName].integrity.split("-")[0];
			result[packageName].integrity = await getHashOf(hashType, snapshot[packageName][version]);

			if (result[packageName].integrity !== dependencies[packageName].integrity)
				console.log(`${packageName}-${version}: ${dependencies[packageName].integrity} -> ${result[packageName].integrity}`);
		}
		 catch (err) {
			console.error(`At: ${packageName}-${version} (${JSON.stringify(snapshot[packageName])})`);
			console.error(err);
		}

		if (dependencies[packageName].dependencies) {
			result[packageName].dependencies = await updateDependencies(snapshot, dependencies[packageName].dependencies);
		};
	}

	return result;
};


(async () => {
	if (process.argv.length < 3) {
		console.log("Usage:");
		console.log(`    ${process.argv[0]} ${process.argv[1]} [snapshot]}`);

		return;
	};

	console.log("Loading Snapshot ...");
	const snapshot = await loadJSONFile(process.argv[2]);

	console.log(`Looking for package locks (in ${process.cwd()}) ...`)
	const foundPackageLocks = await loadAllPackageLocks(process.cwd());
	console.log(`Found: ${foundPackageLocks}`);

	const packageLocks = [];
	console.log("Loading package-locks ...");

	for (const lock of foundPackageLocks) {
		try {
			packageLocks.push({
				parsed: await loadJSONFile(lock),
				path: lock
			});
		}
		catch (err) {
			console.error(`Could not load: ${lock}`);
			console.error(err);
		}
	}

	console.log("Patching locks ...");

	packageLocks.forEach(async (lock) => {
		lock.parsed.dependencies = await updateDependencies(snapshot, lock.parsed.dependencies);
		fs.writeFileSync(lock.path, JSON.stringify(lock.parsed), {encoding:'utf8',flag:'w'});
		console.log(`Patched Sha in file ${lock.path} !`);
	});
})();
