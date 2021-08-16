import fs from "fs"
import crypto from "crypto"

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


export { loadAllPackageLocks, loadJSONFile, getHashOf }
