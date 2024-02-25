import * as fs from 'fs';



/**
 * Get the filename for a file in the test/data directory
 * 
 * @param path 
 * @returns 
 */
export function getDataFilename(path: string): string {
    if (path.startsWith('/')) {
        return path;
    } else {
        return `test/data/${path}`;
    }
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