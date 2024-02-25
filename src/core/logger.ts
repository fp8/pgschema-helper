import { JLogger, LoggerFactory } from 'jlog-facade';

const appLogger = LoggerFactory.create('pgschema-helper');

/**
 * Create logger with name starting with project name.
 *
 * @param name
 * @returns
 */
export function getLogger(name?: string): JLogger {
    if (name) {
        return LoggerFactory.create(`pgschema-helper.${name}`);
    } else {
        return appLogger;
    }  
}
