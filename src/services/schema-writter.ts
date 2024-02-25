import * as nodePath from 'path';
import * as fs from 'fs';
import * as os from 'os';

import { getLogger } from '../core';
import { ParsedSchemaObject, EnumSchemaObjectType, IParsedSchemaObjectRaw } from '../models';



const logger = getLogger('services.SchemaWritter');

// Regular expressions to parse raw schema objects that is fine tuned using parseRawSchemaObjects
const REGEX_SCHEMA_OBJECT = /^-- Name: (.+); Type: ([\w ]+); Schema: (\w+|-); Owner: (\w+)/;
// Regular expressions to extract function name from line
const REGEX_FUNCTION_NAME = /^(\w+)\(/;
// Regular expressions to extract acl name from line
const REGEX_ACL_NAME = /^(\w+) (\w+)[(]?/;
// Regular expressions to extract index table name from line
const REGEX_INDEX_TABLE = /^CREATE (?:UNIQUE )?INDEX .* ON (\w+)\."?(\w+)"?/;

/**
 * Interface for parsed schema object from path
 */
interface IParsedSchemaObjectFromPath {
    schema: string,
    type: EnumSchemaObjectType,
    name: string
}

/**
 * Type for storing parsed object name mapping to type
 */
export type TTableOrView = {
    [name: string]: EnumSchemaObjectType
}

/**
 * Parse the full schema file produced by pgdump
 */
export class SchemaWritter {
    private schemaOutputStream: fs.WriteStream;

    private bufferedSchemaObjects: ParsedSchemaObject | undefined = undefined
    private lineBuffer: string[] = [];

    private tableOrView: TTableOrView = {};

    constructor(private outputDir: string, schemaFileName: string = 'schema.sql') {
        // output dir must be empty
        if (fs.existsSync(this.outputDir)) {
            const files = fs.readdirSync(this.outputDir);
            if (files.length > 0) {
                throw new Error(`Output directory ${this.outputDir} must be empty`);
            }
        } else {
            fs.mkdirSync(this.outputDir, {recursive: true});
        }

        // Create output stream for the output file
        const outfile = `${this.outputDir}/${schemaFileName}`;
        logger.info(`Creating output file ${outfile}`);
        this.schemaOutputStream = fs.createWriteStream(outfile);
    }

    public writeOutput(line: string): void {
        const parsed = parseSchemaObjectFromLine(line);
        if (parsed) {
            this.setTableOrView(parsed);
            this.writeParsedObject(parsed);
        }

        // Needs to amend the parsed object with detail from line
        amendParsedObject(line, this.bufferedSchemaObjects);

        // Write the line to the `schema.sql` file
        this.schemaOutputStream.write(`${line}${os.EOL}`);
        this.lineBuffer.push(line);
    }

    /**
     * As create index can be on a table or a view, we need to track if a name is a table
     * or a view
     *
     * @param parsed 
     */
    private setTableOrView(parsed: ParsedSchemaObject): void {
        if (parsed.type === EnumSchemaObjectType.table || parsed.type === EnumSchemaObjectType.view) {
            this.tableOrView[parsed.name] = parsed.type;
        }
    }

    /**
     * As the delimeter is made of 3 lines such as:
     * 
     * --
     * -- Name: import; Type: SCHEMA; Schema: -; Owner: postgres
     * --
     * 
     * By the time we reached the line starting with `-- Name:`, we already processed the previous `--` line.
     * Need to remove that last line and added to the next buffer
     * 
     * @param parsed 
     */
    private writeParsedObject(parsed: ParsedSchemaObject): void {
        const prevLine = this.lineBuffer.pop();
            
        this.writeBufferedLine(parsed);
        
        if (prevLine) {
            this.lineBuffer = [prevLine];
        } else {
            this.lineBuffer = [];
        }
    }

    /**
     * Write the buffered lines to a file based on IParsedSchemaObject
     * 
     * @param parsed 
     * @returns 
     */
    private writeBufferedLine(parsed: ParsedSchemaObject): void {
        const prevSaved = this.bufferedSchemaObjects;
        this.bufferedSchemaObjects = parsed;

        // If no previously captured schema object, then save it and return
        if (prevSaved === undefined) {
            return;
        }

        const outfile = generateOutputSqlFileName(prevSaved, this.outputDir, this.tableOrView);
        try {
            logger.info(`Writing buffered ${prevSaved.type} object to ${outfile}`);
            fs.appendFileSync(outfile, this.lineBuffer.join(os.EOL));
        } catch (err) {
            if (err instanceof Error) {
                logger.error(`Failed to write buffered schema object to ${outfile}: ${err.message}`, err);
            } else {
                logger.error(`Failed to write buffered schema object to ${outfile}: ${err}`);
            }
            
            throw err;
        }
    }


    public close(): void {
        this.schemaOutputStream.close();
    }

}

/**
 * Need to amend the table name of the parsed object if type is:
 * 
 * - index
 * 
 * @param parsed 
 * @param line 
 */
export function amendParsedObject(line: string, parsed?: ParsedSchemaObject): void {
    if (parsed === undefined) {
        return;
    }

    if (parsed.type === EnumSchemaObjectType.index) {
        const m = REGEX_INDEX_TABLE.exec(line);
        if (m) {
            parsed.table = getMatchedStringByPosition(m, 2, 'table');
            logger.debug(`Amending index object ${parsed.name} with table name: ${parsed.table}`);
        }
    }
}


/**
 * Generate the name of the sql file to write the schema object to
 * 
 * @param input 
 * @param outputDir 
 * @returns 
 */
function generateOutputSqlFileName(input: ParsedSchemaObject, outputDir: string, tableOrView: TTableOrView): string {
    const { schema, type, name } = getObjectForPathFromSchemaObject(input, tableOrView);

    const dirname = nodePath.join(outputDir, schema, type);
    if (!fs.existsSync(dirname)) {
        fs.mkdirSync(dirname, {recursive: true});
    }
    return nodePath.join(dirname, `${name}.sql`);
}

/**
 * Correctly allocate the type to be saved to the object if type is:
 * 
 * - acl
 * - constraint
 * - fk_constraint
 * - index
 * 
 * The expected output is ${outputDir}/${schema}/${type}/${name}.sql
 *
 * @param input 
 * @returns 
 */
export function getObjectForPathFromSchemaObject(input: ParsedSchemaObject, tableOrView: TTableOrView): IParsedSchemaObjectFromPath {
    const schema = input.schema;
    let type = input.type;
    let name = input.name;
    
    if (type === EnumSchemaObjectType.acl) {
        if (input.acl_type === undefined) {
            throw new Error(`Failed to parse acl_type from ${input}`);
        }
        type = input.acl_type;
    } else if (
        type === EnumSchemaObjectType.constraint
        || type === EnumSchemaObjectType.fk_constraint
        || type === EnumSchemaObjectType.index
    ) {
        if (input.table === undefined) {
            throw new Error(`Failed to parse table name from ${type} type from ${JSON.stringify(input)}`);
        }
        name = input.table

        // Need to source correct type from tableOrView
        if (tableOrView && name in tableOrView) {
            type = tableOrView[name];
        } else {
            type = EnumSchemaObjectType.table;
        }
    }

    return { schema, type, name };
}


/**
 * Return the matched string from the input array at the specified position
 * 
 * @param input 
 * @param position 
 * @param message 
 * @returns 
 */
function getMatchedStringByPosition(input: RegExpExecArray, position: number, message: string): string {
    let result: string | undefined = undefined;
    if (input && input.length > position) {
        let positionResult = input[position];
        if (positionResult) {
            positionResult = positionResult.trim();
            if (positionResult.length > 0) {
                result = positionResult;
            }
        }
    }

    if (result) {
        return result;
    } else {
        throw new Error(`Failed to parse ${message} from ${input}`);
    }
}

/**
 * This function parses the raw schema object obtained from following in the schema file:
 * 
 * * `-- Name: fun_get_rpt_date_by_int_date(integer); Type: FUNCTION; Schema: public; Owner: exa_db`
 * 
 * It returns a [ParsedSchemaObject] instance to signal the that a new file should be created to
 * host the data of that object.  If it returns undefined, it means that the section follwing
 * the `-- Name:` line should be appended to the previous file.
 * 
 * @param input 
 */
function parseRawSchemaObjects(input: ParsedSchemaObject): ParsedSchemaObject | undefined {
    const owner = input.owner;
    const type = ParsedSchemaObject.parseType(input.type);

    let name = input.name;
    let schema = input.schema;

    // Optional fields
    let table: string | undefined = undefined;
    let fk_table: string | undefined = undefined;
    let acl_type: EnumSchemaObjectType | undefined = undefined;


    switch (type) {
        /**
         * Do not process sequence so it can be collected with the table
         */
        case EnumSchemaObjectType.sequence:
            return;

        /**
         * Parse: `-- Name: bus_model bus_model_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db`
         * 
         * where the name of the constraint is `bus_model_pkey` and the table is `bus_model`
         */
        case EnumSchemaObjectType.constraint: {
            if (name.indexOf(' ') > -1) {
                const parts = name.split(' ');
                name = parts[1];
                table = parts[0];
            }
            break;
        }

        /**
         * Parse: `-- Name: bus_model bus_model_bank; Type: FK CONSTRAINT; Schema: import; Owner: exa_db`
         * 
         * where the name of the constraint is build to become `bus_model_FK_bus_model_bank` and the table is `bus_model`
         */
        case EnumSchemaObjectType.fk_constraint: {
            if (name.indexOf(' ') > -1) {
                const parts = name.split(' ');
                table = parts[0];
                fk_table = parts[1];
                name = `${table}_FK_${fk_table}`;
            }
            break;
        }

        /**
         * Parse: `-- Name: import; Type: SCHEMA; Schema: -; Owner: postgres`
         * 
         * Set the schema to be the name as it is returned as `-`
         */
        case EnumSchemaObjectType.schema: {
            schema = name;
            break;
        }

        /**
         * Parse: `-- Name: fun_active_rec_source_ref(date); Type: FUNCTION; Schema: public; Owner: exa_db`
         * 
         * Extract the function name of `fun_active_rec_source_ref` from `fun_active_rec_source_ref(date)` using
         * regex REGEX_FUNCTION_NAME.  If regex fails to match, throw an error.
         */
        case EnumSchemaObjectType.function: {
            const m = REGEX_FUNCTION_NAME.exec(name);
            if (m) {
                name = getMatchedStringByPosition(m, 1, name);
            } else {
                throw new Error(`Failed to parse function name from ${name}`);
            }
            break;
        }

        /**
         * Parse: `-- Name: p_apm_file_monitor_status_process(date); Type: PROCEDURE; Schema: public; Owner: exa_db`
         * 
         * Extract the function name of `p_apm_file_monitor_status_process` from `p_apm_file_monitor_status_process(date)` using
         * regex REGEX_FUNCTION_NAME.  If regex fails to match, throw an error.
         */
        case EnumSchemaObjectType.procedure: {
            const m = REGEX_FUNCTION_NAME.exec(name);
            if (m) {
                name = getMatchedStringByPosition(m, 1, name);
            } else {
                throw new Error(`Failed to parse function name from ${name}`);
            }
            break;
        }

        /**
         * Parse: `-- Name: abi_gdl; Type: TABLE; Schema: import; Owner: exa_db`
         * 
         * Set the table to be the parsed name
         */
        case EnumSchemaObjectType.table: {
            table = name;
            break;
        }

        /**
         * Parse: `-- Name: TABLE limit_value; Type: ACL; Schema: public; Owner: exa_db`
         * 
         * Parse the `TABLE limit_value` and set the name to `limit_value` and the acl_type to `table` using
         * regex REGEX_ACL_NAME.  If regex fails to match, throw an error.
         */
        case EnumSchemaObjectType.acl: {
            const m = REGEX_ACL_NAME.exec(name);
            if (m) {
                name = getMatchedStringByPosition(m, 2, 'name');
                acl_type = ParsedSchemaObject.parseType(getMatchedStringByPosition(m, 1, 'acl_type').toLowerCase());
            } else {
                throw new Error(`Failed to parse acl name from ${name}`);
            }

            if (acl_type === EnumSchemaObjectType.schema) {
                schema = name;
            }
            break;
        }

        /**
         * No default.  If case is not triggered, leave the fields as is from raw parsed object
         */
    }

    const output = ParsedSchemaObject.create({name, type, schema, owner});

    // Set the optional fields
    if (table) {
        output.table = table;
    }
    if (fk_table) {
        output.fk_name = fk_table;
    }
    if (acl_type) {
        output.acl_type = acl_type;
    }

    return output;
}

/**
 * Parse output of pg_dump command for db objects
 * 
 * -- Name: enum_apm_file_monitor_status; Type: TYPE; Schema: public; Owner: exa_db
 * -- Name: portfolio_info portfolio_info_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
 * -- Name: idx_position_portfolio_position_type; Type: INDEX; Schema: public; Owner: exa_db
 * 
 * @param line 
 * @returns 
 */
export function parseSchemaObjectFromLine(line: string): ParsedSchemaObject | undefined {
    // Only continue if line starts with '-- Name:'
    if (!line.startsWith('-- Name:')) {
        return undefined;  
    }

    // Run regex against line
    const m = REGEX_SCHEMA_OBJECT.exec(line);
    if (m) {
        const rawObjects: IParsedSchemaObjectRaw = {
            name: getMatchedStringByPosition(m, 1, 'name'),
            type: getMatchedStringByPosition(m, 2, 'type').toLocaleLowerCase() as EnumSchemaObjectType,
            schema: getMatchedStringByPosition(m, 3, 'schema'),
            owner: getMatchedStringByPosition(m, 4, 'owner')
        };

        return parseRawSchemaObjects(rawObjects);
    } else {
        logger.error(`Failed to parse line: ${line}`);
    }

    return undefined;
}
