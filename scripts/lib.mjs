import fsPromises from "fs/promises";
import crypto from "crypto";

const loadAllPackageLocks = (root) =>
	fsPromises.readdir(root, { withFileTypes: true })
		.then(files =>
			files.reduce(async (locksP, file) => {
				const fileName = `${root}/${file.name}`;
				const locks = await locksP;

				return file.isDirectory() ?
					[...locks, ...(await loadAllPackageLocks(fileName))]
					: (file.name === "package-lock.json") ?
						[...locks, fileName] :
						locks;
			}, Promise.resolve([])));

const loadJSONFile = (file) => fsPromises.readFile(file, { encoding: 'utf8' }).then(JSON.parse);

const getHashOf = (type, file) => fsPromises.readFile(file).then((contents) => {
	const hash = crypto.createHash(type);
	hash.setEncoding("hex");
	hash.update(contents);
	return `${type}-${hash.digest('base64')}`;
});

export { loadAllPackageLocks, loadJSONFile, getHashOf }
