import fsPromises from "fs/promises";
import crypto from "crypto";

const loadAllPackageLocks = async (root) => {
	const files = await fsPromises.readdir(root, { withFileTypes: true });

	return await files.reduce(async (locksP, file) => {
		const fileName = `${root}/${file.name}`;
		const locks = await locksP;

		if (file.isDirectory())
			return [...locks, ...(await loadAllPackageLocks(fileName))];

		if (file.name === "package-lock.json")
			return [...locks, fileName];

		return locks;
	}, Promise.resolve([]));
};

const loadJSONFile = (file) => fsPromises.readFile(file, { encoding: 'utf8' }).then(JSON.parse);

const getHashOf = (type, file) => fsPromises.readFile(file).then((contents) => {
	const hash = crypto.createHash(type);
	hash.setEncoding("hex");
	hash.update(contents);
	return `${type}-${hash.digest('base64')}`;
});

const mapOverAttrsAsync = async (lambda, set) => {
	const set_copy = { ...set };

	for (const attrName in set) {
		set_copy[attrName] = await lambda(attrName, set_copy[attrName]);
	}

	return set_copy;
};

export { loadAllPackageLocks, loadJSONFile, getHashOf, mapOverAttrsAsync }
