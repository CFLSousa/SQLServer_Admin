/*
*Procedimento para obter a listagem completa de passageiros por voo.
*Inclui passageiros e funcionários da transportadora aerea.
*/
CREATE PROCEDURE [dbo].[usp_ListaPassageiros](@VooId int)
AS
	BEGIN
		SELECT distinct p.[pass_id],
			p.[pass_nome],
			v.[voo_data] as VooData,
			v.[voo_part] as VooPartida,
			v.[voo_dest] as VooChegada
		FROM [dbo].[voo] v INNER JOIN [dbo].[reserva] r
			ON v.[voo_id]=r.[voo_id]
				INNER JOIN [dbo].[passageiro] p
				ON r.[pass_id]=p.[pass_id]
		WHERE r.[voo_id]=@VooId
		UNION ALL
		SELECT distinct f.[func_id],
			f.[func_nome],
			v.[voo_data] as VooData,
			v.[voo_part] as VooPartida,
			v.[voo_dest] as VooChegada
		FROM [dbo].[voo] v INNER JOIN [dbo].[reserva] r
			ON v.[voo_id]=r.[voo_id]
					INNER JOIN [dbo].[escala] e
					ON v.[voo_id]=e.[voo_id]
						INNER JOIN [dbo].[funcionario] f
						ON e.[esc_id]=f.[esc_id]
		WHERE r.[voo_id]=@VooId;
	END
GO