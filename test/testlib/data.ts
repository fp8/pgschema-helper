import * as fs from 'fs';



export function getDataFilename(path: string): string {
    if (path.startsWith('/')) {
        return path;
    } else {
        return `test/data/${path}`;
    }
}

/**
 * Return a path as a stream
 *
 * @param path 
 * @returns 
 */
export function loadDataFileAsStream(path: string): fs.ReadStream {
    const filepath = getDataFilename(path);
    return fs.createReadStream(filepath, {encoding: 'utf8'});
}

/**
 * Read a json file and return the parsed object
 *
 * @param path 
 * @returns 
 */
export function loadDataFile<T>(path: string): T {
    const filepath = getDataFilename(path);
    const text = fs.readFileSync(filepath, {encoding: 'utf8'});
    return JSON.parse(text);
}