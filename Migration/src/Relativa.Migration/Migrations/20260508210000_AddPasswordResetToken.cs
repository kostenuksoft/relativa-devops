using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

using Relativa.Migration.Data;

using EfMigration = Microsoft.EntityFrameworkCore.Migrations.Migration;

#nullable disable

namespace Relativa.Migration.Migrations;

[DbContext(typeof(MigrationDbContext))]
[Migration("20260508210000_AddPasswordResetToken")]
public partial class AddPasswordResetToken : EfMigration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(
            """
            ALTER TABLE users
                ADD COLUMN IF NOT EXISTS password_reset_token TEXT NULL,
                ADD COLUMN IF NOT EXISTS password_reset_token_expires_at TIMESTAMPTZ NULL;
            """);
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(
            """
            ALTER TABLE users
                DROP COLUMN IF EXISTS password_reset_token,
                DROP COLUMN IF EXISTS password_reset_token_expires_at;
            """);
    }
}
