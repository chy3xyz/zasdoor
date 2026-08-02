//! zent schema-as-code — uploaded file metadata.
//!
//! File bytes live on the local disk under the configured upload directory;
//! the `File` row keeps name, size, mime type, storage key and uploader.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const File = Schema("File", .{
    .fields = &.{
        field.String("name"),
        field.String("storage_key"),
        field.String("mime").Default("application/octet-stream"),
        field.Int("size_bytes").Default(0),
        field.Int("uploader_id").Default(0),
        field.Int("tenant_id").Default(1),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
