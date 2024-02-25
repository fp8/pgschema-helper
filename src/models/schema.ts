import { IsString, IsEnum, IsOptional } from 'class-validator';
import { Loggable } from 'jlog-facade';
import { createEntityAndValidate, EntityCreationError } from '@fp8/simple-config';

import { getLogger } from '../core/logger';

const logger = getLogger('models.schema');

export enum EnumSchemaObjectType {
    schema = 'schema',
    table = 'table',
    constraint = 'constraint',
    fk_constraint = 'fk_constraint',
    index = 'index',
    acl = 'acl',
    view = 'view',
    function = 'function',
    procedure = 'procedure',
    sequence = 'sequence',
    default = 'default',
    type = 'type',
}


export interface IParsedSchemaObjectRaw {
    name: string;
    type: EnumSchemaObjectType;
    schema: string;
    owner: string;
}

/**
 * Designed to house data parsed from:
 * 
 * -- Name: enum_apm_file_monitor_status; Type: TYPE; Schema: public; Owner: exa_db
 */
export class ParsedSchemaObject implements IParsedSchemaObjectRaw {
    static create(input: Partial<ParsedSchemaObject>): ParsedSchemaObject {
        if (input.type) {
            input.type = ParsedSchemaObject.parseType(input.type);
        }
        try {
            return createEntityAndValidate(ParsedSchemaObject, input)
        } catch (err) {
            if (err instanceof EntityCreationError) {
                logger.warn('Validation failed for fields:', Loggable.of('fileds', err.fields));
              } else {
                logger.warn(`Unknown validation error: ${err}`);
              }
              throw err;
        }
    }

    /**
     * Parsed type from schema file requires further process to be used as EnumSchemaObjectType
     * 
     * @param input 
     * @returns 
     */
    static parseType(input: string): EnumSchemaObjectType {
        let type = input.toLowerCase();
            
        if (type === 'fk constraint') {
            type = EnumSchemaObjectType.fk_constraint;
        } else if (type === 'sequence owned by') {
            type = EnumSchemaObjectType.sequence;
        } else if (type === 'materialized view') {
            type = EnumSchemaObjectType.view;
        }

        return type as EnumSchemaObjectType;
    }

    @IsString()
    name!: string;

    @IsEnum(EnumSchemaObjectType)
    type!: EnumSchemaObjectType;

    @IsString()
    schema!: string;

    @IsString()
    owner!: string;

    @IsOptional()
    @IsString()
    table?: string;

    @IsOptional()
    @IsString()
    fk_name?: string;

    @IsOptional()
    @IsEnum(EnumSchemaObjectType)
    acl_type?: EnumSchemaObjectType;
}
