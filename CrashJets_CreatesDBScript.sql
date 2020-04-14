-------------------------------------------------------------------------------------------------------------------------------------
/*
*Use master to Create Database CrashJets
*/
USE master
GO
-------------------------------
--Create Database CrashJets--
-------------------------------
CREATE DATABASE CrashJets 
ON PRIMARY (NAME = N'CrashJets_Primary', FILENAME = N'C:\CrashJets\CrashJets_Principal.mdf', SIZE = 128 MB, MAXSIZE = 256 MB, FILEGROWTH = 0),

FILEGROUP CrashJets_Filegroup DEFAULT (NAME = N'C:\CrashJets\CrashJets_Secondary01', FILENAME = N'C:\CrashJets\MyCrashJets_Secondary01.ndf', SIZE = 128 MB, MAXSIZE = 256 MB, FILEGROWTH = 0)

LOG ON (NAME = N'CrashJets_Log', FILENAME = N'C:\CrashJets\CrashJets.ldf', SIZE = 1024 MB, MAXSIZE = 2048 MB, FILEGROWTH = 0)
GO
/*
*Use CrashJets
*/
USE CrashJets
GO
-------------------------------------------------------------------------------------------------------------------------------------
----------------------------------
-------------Funções--------------
----------------------------------
/*
*Função para calcular o preço final da reserva segundo a fórmula:
*
*pr_fin=(pr_b+extr)*((100-perc_desc)/100)
*
*/
CREATE FUNCTION [dbo].[udf_GetPrecoFinal](@VooId int,@PrecoExtras int,@PassId int)
RETURNS INT
AS
	BEGIN
		DECLARE @PrecoFinal INT;
		DECLARE @PercDesc INT;
		DECLARE @PrecoAlvo INT;
		SET @PrecoFinal=0;
		SET @PercDesc=(select (isnull(
							(select perc_desc from desconto 
								where (select cartao_milhas from passageiro where pass_id=@PassId) 
								between milhas_min and milhas_max)
						,0)));
		SET @PrecoAlvo=(select (v.preco_base+@PrecoExtras)
						from voo v where v.voo_id=@VooId);	

		SET @PrecoFinal=(
				@PrecoAlvo-((@PrecoAlvo*@PercDesc)/100)
		);
		RETURN ROUND(@PrecoFinal,0);
	END
GO
/*
*Função para verificar se a data da reserva é anterior à data do voo
*/
CREATE FUNCTION [dbo].[udf_IsValidResData](@ResData datetime,@ResVooId int)
RETURNS BIT
AS
	BEGIN
		DECLARE @Flag BIT;
		SET @Flag=0;
		IF(@ResData<(select voo_data from voo where voo_id=@ResVooId))
			BEGIN
				SET @Flag=1;
			END	
		RETURN @Flag;
	END
GO
/*
*Função para verificar se a duração do voo é superior a 2 horas
*/
CREATE FUNCTION [dbo].[udf_IsVooDurMaior2H](@ResVooId int)
RETURNS BIT
AS
	BEGIN
		DECLARE @Flag BIT;
		SET @Flag=0;
		IF((select voo_dur from voo where voo_id=@ResVooId)>'02:00:00')
			BEGIN
				SET @Flag=1;
			END	
		RETURN @Flag;
	END
GO
/*
*Função para verificar se a data de partida e a data de chegada do voo não coincide com a data de manutenção do avião.
*Um voo que se realize num determinado intervalo de datetimes só pode ser realizado por um avião que não esteja em manutenção nesse intervalo de datetimes.
*/
CREATE FUNCTION [dbo].[udf_AviaoEstaDisponivel](@AviaoId int,@VooId int)
RETURNS BIT
AS
	BEGIN
		DECLARE @Flag BIT;
		DECLARE @VooData datetime;
		DECLARE @VooDur datetime;
		DECLARE @DataFimVoo datetime;
		DECLARE @DataManut datetime;
		SET @Flag=0;
		SET @VooData=(select voo_data from voo where voo_id=@VooId);
		SET @VooDur=(select (cast(voo_dur as datetime)) from voo where voo_id=@VooId);
		SET @DataFimVoo=(@VooData+@VooDur);
		SET @DataManut=(cast((select data_manut from aviao where av_id=@AviaoId) as datetime));
		IF(
			(
				cast(@DataFimVoo as date)
				<>
				cast(@DataManut as date)
			)
			AND
			(
				cast(@VooData as date)
				<>
				cast(@DataManut as date)
			)
		)
			BEGIN
				SET @Flag=1;
			END	
		RETURN @Flag;
	END
GO
-------------------------------------------------------------------------------------------------------------------------------------
----------------------------------
----------Procedimentos-----------
----------------------------------
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
/*
*Transação de reserva de um voo com validação de lotação do aviao
*/
CREATE PROCEDURE [dbo].[usp_EfetuarReserva](@VooId int,@PassId int,@RefId int,@PrecoExtras int)
AS
	BEGIN
		DECLARE @Capacidade INT;
		DECLARE @ReservasFeitas INT;
		DECLARE @CartaoMilhas INT;
		DECLARE @DistMilhas INT;
		SET @Capacidade=0;
		SET @ReservasFeitas=0;
		SET @CartaoMilhas=0;
		SET @DistMilhas=0;
		
		SELECT @Capacidade=a.[av_lot]
			from aviao a inner join voo v on v.av_id=a.av_id
			where v.[voo_id]=@VooId;

		SELECT @ReservasFeitas=(count(r.res_id))
				from reserva r inner join voo v on r.voo_id=v.voo_id
				where (r.voo_id=@VooId);
				
		IF(@ReservasFeitas<@Capacidade)
			begin
				BEGIN TRANSACTION;
					IF((([dbo].[udf_IsVooDurMaior2H](@VooId))=1))
						begin
							INSERT [dbo].[reserva]([bilhete_emitido],[res_data],[voo_id],[pass_id],[ref_id],[preco_extras]) 
								VALUES
									('S',getdate(),@VooId,@PassId,@RefId,@PrecoExtras);		
						end
					ELSE
						begin
							INSERT [dbo].[reserva]([bilhete_emitido],[res_data],[voo_id],[pass_id],[ref_id],[preco_extras]) 
								VALUES
									('S',getdate(),@VooId,@PassId,null,@PrecoExtras);		
						end
					SELECT @CartaoMilhas=[cartao_milhas] from passageiro where pass_id=@PassId;
					SELECT @DistMilhas=[dist_milhas] from voo where voo_id=@VooId;
					UPDATE passageiro
						set cartao_milhas=(@CartaoMilhas+@DistMilhas)
						where pass_id=@PassId;
				COMMIT;
			end
		ELSE
			begin
				print isnull(N'Overbooking.','(null)');
			end
	END
GO
/*
*Procedimento para obter horário e lotação de determinado voo
*/
CREATE PROCEDURE [dbo].[usp_Lotacao](@VooId int)
AS
	BEGIN
		DECLARE @Capacidade INT;
		DECLARE @ReservasFeitas INT;
		SET @Capacidade=0;
		SET @ReservasFeitas=0;

		SELECT @Capacidade=a.[av_lot]
			from aviao a inner join voo v on v.av_id=a.av_id
			where v.[voo_id]=@VooId;

		SELECT @ReservasFeitas=(count(r.res_id))
				from reserva r inner join voo v on r.voo_id=v.voo_id
				where (r.voo_id=@VooId);

		IF(@ReservasFeitas<@Capacidade)
			begin
				SELECT [voo_id],[voo_data],[voo_part],[voo_dest],(@Capacidade-@ReservasFeitas) as Vagas 
					from voo where voo_id=@VooId;
			end
		ELSE 
			begin
				SELECT [voo_id],[voo_data],[voo_part],[voo_dest],'Lotação Esgotada' as Vagas 
					from voo where voo_id=@VooId;
			end
	END
GO
-------------------------------------------------------------------------------------------------------------------------------------
----------------------
-----CREATE Tables----
----------------------
/*
*Create Table aviao
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[aviao](
	[av_id] [int] IDENTITY(1,1) constraint aviao_av_id_nn NOT NULL,
	[av_lot] [int] constraint aviao_av_lot_nn NOT NULL,
	[av_nome] [nvarchar](250) constraint aviao_av_nome_nn NOT NULL,
	[data_manut] [date] constraint aviao_data_manut_nn NOT NULL,
 CONSTRAINT [aviao_av_id_pk] PRIMARY KEY CLUSTERED 
(
	[av_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/*
*Create Table refeicao
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[refeicao](
	[ref_id] [int] IDENTITY(1,1) constraint refeicao_ref_id_nn NOT NULL,
	[ref_tipo] [nvarchar](100) constraint refeicao_ref_tipo_nn NOT NULL,
 CONSTRAINT [refeicao_ref_id_pk] PRIMARY KEY CLUSTERED 
(
	[ref_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/*
*Create Table passageiro
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[passageiro](
	[pass_id] [int] IDENTITY(1,1) constraint passageiro_pass_id_nn NOT NULL,
	[pass_nome] [nvarchar](100) constraint passageiro_pass_nome_nn NOT NULL,
	[cartao_milhas] [int] constraint passageiro_cartao_milhas_nn NOT NULL,
 CONSTRAINT [passageiro_pass_id_pk] PRIMARY KEY CLUSTERED 
(
	[pass_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/*
*Create Table desconto
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[desconto](
	[desc_id] [int] constraint desconto_desc_id_nn NOT NULL,
	[milhas_min] [bigint] constraint desconto_milhas_min_nn NOT NULL,
	[milhas_max] [bigint] constraint desconto_milhas_max_nn NOT NULL,
	[perc_desc] [int] constraint desconto_perc_desc_nn NOT NULL,
 CONSTRAINT [desconto_desc_id_pk] PRIMARY KEY CLUSTERED 
(
	[desc_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/*
*Create Table voo
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[voo](
	[voo_id] [int] IDENTITY(1,1) constraint voo_voo_id_nn NOT NULL,
	[voo_dur] [time] constraint voo_voo_dur_nn NOT NULL,
	[voo_data] [datetime] constraint voo_voo_data_nn NOT NULL,
	[voo_part] [nvarchar](100) constraint voo_voo_part_nn NOT NULL,
	[voo_dest] [nvarchar](100) constraint voo_voo_dest_nn NOT NULL,
	[preco_base] [int] constraint voo_preco_base_nn NOT NULL,
	[dist_milhas] [int] constraint voo_dist_milhas_nn NOT NULL,
	[av_id] [int] constraint voo_av_id_nn NOT NULL,
 CONSTRAINT [voo_voo_id_pk] PRIMARY KEY CLUSTERED 
(
	[voo_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/*
*Create Table escala
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[escala](
	[esc_id] [int] IDENTITY(1,1) constraint escala_esc_id_nn NOT NULL,
	[esc_data_ini] [datetime] constraint escala_esc_data_ini_nn NOT NULL,
	[esc_data_fim] [datetime] constraint escala_esc_data_fim_nn NOT NULL,
	[voo_id] [int] constraint escala_voo_id_nn NOT NULL,
 CONSTRAINT [escala_esc_id_pk] PRIMARY KEY CLUSTERED 
(
	[esc_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/*
*Create Table funcionario
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[funcionario](
	[func_id] [int] IDENTITY(1,1) constraint funcionario_func_id_nn NOT NULL,
	[func_nome] [nvarchar](250) constraint funcionario_func_nome_nn NOT NULL,
	[func_tipo] [nvarchar](100) constraint funcionario_func_tipo_nn NOT NULL,
	[esc_id] [int] NULL,
 CONSTRAINT [funcionario_func_id_pk] PRIMARY KEY CLUSTERED 
(
	[func_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
/*
*Create Table reserva
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[reserva](
	[res_id] [int] IDENTITY(1,1) constraint reserva_res_id_nn NOT NULL,
	[bilhete_emitido] [nchar](1) constraint reserva_bilhete_emitido_nn NOT NULL,
	[res_data] [datetime] constraint reserva_res_data_nn NOT NULL,
	[voo_id] [int] constraint reserva_voo_id_nn NOT NULL,
	[pass_id] [int] constraint reserva_pass_id_nn NOT NULL,
	[ref_id] [int] NULL,
	[preco_extras] [int] constraint reserva_preco_extras_nn NOT NULL default 0,
	preco_final as [dbo].[udf_GetPrecoFinal]([voo_id],[preco_extras],[pass_id]),
 CONSTRAINT [reserva_res_id_pk] PRIMARY KEY CLUSTERED 
(
	[res_id] ASC
)WITH (PAD_INDEX  = OFF, STATISTICS_NORECOMPUTE  = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS  = ON, ALLOW_PAGE_LOCKS  = ON) ON [PRIMARY]
) ON [PRIMARY]
GO
-------------------------------------------------------------------------------------------------------------------------------------
----------------------------------
-------Adicionar restrições-------
----------------------------------
ALTER TABLE [dbo].[aviao]  WITH CHECK ADD  CONSTRAINT [aviao_maximo_avioes_ck] CHECK([av_id]<=20)
GO
ALTER TABLE [dbo].[aviao] CHECK CONSTRAINT [aviao_maximo_avioes_ck]
GO
ALTER TABLE [dbo].[aviao]  WITH CHECK ADD  CONSTRAINT [aviao_av_lot_ck] CHECK([av_lot] IN(80,120,140))
GO
ALTER TABLE [dbo].[aviao] CHECK CONSTRAINT [aviao_av_lot_ck]
GO
ALTER TABLE [dbo].[aviao]  WITH CHECK ADD  CONSTRAINT [aviao_data_manut_ck] CHECK([data_manut]>cast(getDate() as date))
GO
ALTER TABLE [dbo].[aviao] CHECK CONSTRAINT [aviao_data_manut_ck]
GO
ALTER TABLE [dbo].[refeicao]  WITH CHECK ADD  CONSTRAINT [refeicao_ref_tipo_ck] CHECK([ref_tipo] IN('Normal','Dieta','Vegetariana'))
GO
ALTER TABLE [dbo].[refeicao] CHECK CONSTRAINT [refeicao_ref_tipo_ck]
GO
ALTER TABLE [dbo].[passageiro]  WITH CHECK ADD  CONSTRAINT [desconto_cartao_milhas_ck] CHECK([cartao_milhas]>=0)
GO
ALTER TABLE [dbo].[passageiro] CHECK CONSTRAINT [desconto_cartao_milhas_ck]
GO
ALTER TABLE [dbo].[desconto]  WITH CHECK ADD  CONSTRAINT [desconto_milhas_min_ck] CHECK([milhas_min]>=1000)
GO
ALTER TABLE [dbo].[desconto] CHECK CONSTRAINT [desconto_milhas_min_ck]
GO
ALTER TABLE [dbo].[desconto]  WITH CHECK ADD  CONSTRAINT [desconto_milhas_max_ck] CHECK([milhas_max]>[milhas_min])
GO
ALTER TABLE [dbo].[desconto] CHECK CONSTRAINT [desconto_milhas_max_ck]
GO
ALTER TABLE [dbo].[voo]  WITH CHECK ADD  CONSTRAINT [voo_av_id_fk] FOREIGN KEY([av_id])
REFERENCES [dbo].[aviao] ([av_id])
GO
ALTER TABLE [dbo].[voo] CHECK CONSTRAINT [voo_av_id_fk]
GO
ALTER TABLE [dbo].[voo]  WITH CHECK ADD  CONSTRAINT [voo_voo_data_ck] CHECK([voo_data]>getDate())
GO
ALTER TABLE [dbo].[voo] CHECK CONSTRAINT [voo_voo_data_ck]
GO
ALTER TABLE [dbo].[voo]  WITH CHECK ADD  CONSTRAINT [voo_preco_base_ck] CHECK([preco_base]>0)
GO
ALTER TABLE [dbo].[voo] CHECK CONSTRAINT [voo_preco_base_ck]
GO
ALTER TABLE [dbo].[voo]  WITH CHECK ADD  CONSTRAINT [voo_dist_milhas_ck] CHECK([dist_milhas]>0)
GO
ALTER TABLE [dbo].[voo] CHECK CONSTRAINT [voo_dist_milhas_ck]
GO
ALTER TABLE [dbo].[voo]  WITH CHECK ADD  CONSTRAINT [voo_aviao_disponivel_ck] CHECK(([dbo].[udf_AviaoEstaDisponivel]([av_id],[voo_id]))=1)
GO
ALTER TABLE [dbo].[voo] CHECK CONSTRAINT [voo_aviao_disponivel_ck]
GO
ALTER TABLE [dbo].[escala]  WITH CHECK ADD  CONSTRAINT [escala_voo_id_fk] FOREIGN KEY([voo_id])
REFERENCES [dbo].[voo] ([voo_id])
GO
ALTER TABLE [dbo].[escala] CHECK CONSTRAINT [escala_voo_id_fk]
GO
ALTER TABLE [dbo].[escala]  WITH CHECK ADD  CONSTRAINT [escala_esc_data_fim_ck] CHECK([esc_data_fim]>[esc_data_ini])
GO
ALTER TABLE [dbo].[escala] CHECK CONSTRAINT [escala_esc_data_fim_ck]
GO
ALTER TABLE [dbo].[funcionario]  WITH CHECK ADD  CONSTRAINT [funcionario_maximo_funcionarios_ck] CHECK([func_id]<=120)
GO
ALTER TABLE [dbo].[funcionario] CHECK CONSTRAINT [funcionario_maximo_funcionarios_ck]
GO
ALTER TABLE [dbo].[funcionario]  WITH CHECK ADD  CONSTRAINT [funcionario_esc_id_fk] FOREIGN KEY([esc_id])
REFERENCES [dbo].[escala] ([esc_id])
GO
ALTER TABLE [dbo].[funcionario] CHECK CONSTRAINT [funcionario_esc_id_fk]
GO
ALTER TABLE [dbo].[funcionario]  WITH CHECK ADD  CONSTRAINT [funcionario_func_tipo_ck] CHECK([func_tipo] IN('Tripulação','Assistente de Embarque','Apoio Administrativo'))
GO
ALTER TABLE [dbo].[funcionario] CHECK CONSTRAINT [funcionario_func_tipo_ck]
GO
ALTER TABLE [dbo].[reserva]  WITH CHECK ADD  CONSTRAINT [reserva_ref_id_fk] FOREIGN KEY([ref_id])
REFERENCES [dbo].[refeicao] ([ref_id])
GO
ALTER TABLE [dbo].[reserva] CHECK CONSTRAINT [reserva_ref_id_fk]
GO
ALTER TABLE [dbo].[reserva]  WITH CHECK ADD  CONSTRAINT [reserva_pass_id_fk] FOREIGN KEY([pass_id])
REFERENCES [dbo].[passageiro] ([pass_id])
GO
ALTER TABLE [dbo].[reserva] CHECK CONSTRAINT [reserva_pass_id_fk]
GO
ALTER TABLE [dbo].[reserva]  WITH CHECK ADD  CONSTRAINT [reserva_voo_id_fk] FOREIGN KEY([voo_id])
REFERENCES [dbo].[voo] ([voo_id])
GO
ALTER TABLE [dbo].[reserva] CHECK CONSTRAINT [reserva_voo_id_fk]
GO
ALTER TABLE [dbo].[reserva]  WITH CHECK ADD  CONSTRAINT [reserva_bilhete_emitido_ck] CHECK([bilhete_emitido] IN('S','N'))
GO
ALTER TABLE [dbo].[reserva] CHECK CONSTRAINT [reserva_bilhete_emitido_ck]
GO
ALTER TABLE [dbo].[reserva]  WITH CHECK ADD  CONSTRAINT [reserva_preco_extras_ck] CHECK([preco_extras]>=0)
GO
ALTER TABLE [dbo].[reserva] CHECK CONSTRAINT [reserva_preco_extras_ck]
GO
ALTER TABLE [dbo].[reserva]  WITH CHECK ADD  CONSTRAINT [reserva_res_data_ck] CHECK(([dbo].[udf_IsValidResData]([res_data],[voo_id]))=1)
GO
ALTER TABLE [dbo].[reserva] CHECK CONSTRAINT [reserva_res_data_ck]
GO
ALTER TABLE [dbo].[reserva]  WITH CHECK ADD  CONSTRAINT [reserva_tem_refeicao_ck] CHECK(
	((([dbo].[udf_IsVooDurMaior2H]([voo_id]))!=1) AND (ref_id is null))
	OR
	((([dbo].[udf_IsVooDurMaior2H]([voo_id]))=1) AND (ref_id IN(1,2,3))))
GO
ALTER TABLE [dbo].[reserva] CHECK CONSTRAINT [reserva_tem_refeicao_ck]
GO
-------------------------------------------------------------------------------------------------------------------------------------
--------------------------------------
--Insert's de informação nas tabelas--
--------------------------------------
/*
*Insert's tabela aviao
*/
INSERT INTO [dbo].[aviao]([av_lot],[av_nome],[data_manut]) VALUES
	(80,N'Hercules','2019-07-16'),
	(140,N'Tiger','2019-07-17'),
	(120,N'Falcon','2019-07-18'),
	(120,N'Eagle','2019-07-19'),
	(120,N'Victory','2019-07-19'),
	(80,N'Airbus','2019-07-20'),
	(80,N'Hammer','2019-07-21'),
	(140,N'Boeing','2019-07-22'),
	(80,N'Orange','2019-07-23'),
	(140,N'Pumpkin','2019-07-24'),
	(120,N'Spirit','2019-07-25'),
	(140,N'Apollo','2019-07-26'),
	(120,N'Pilot','2019-07-26'),
	(80,N'Rocket','2019-07-27'),
	(80,N'Cessna','2019-07-28'),
	(80,N'Raptor','2019-07-29'),
	(80,N'Phantom','2019-07-30'),
	(120,N'Tomcat','2019-07-30'),
	(140,N'Blackbird','2019-07-16'),
	(80,N'Concorde','2019-07-17')
GO
/*
*Insert's tabela refeicao
*/
INSERT [dbo].[refeicao]([ref_tipo]) VALUES
	(N'Normal'),
	(N'Dieta'),
	(N'Vegetariana')
GO
/*
*Insert's tabela passageiro
*/
INSERT [dbo].[passageiro]([pass_nome],[cartao_milhas]) VALUES 
	(N'João Marques',250),
	(N'Vitor Gelásio',500),
	(N'Artur Ramos',5000),
	(N'Alberto Cardoso',300),
	(N'Nuno Sousa',2500),
	(N'António Costa',250),
	(N'Ana Cunha',600),
	(N'José Sócrates',60000),
	(N'Vitor Sobral',1000),
	(N'Mister T',10000),
	(N'Jonh Cooper',500),
	(N'Ruby Riott',5000),
	(N'Liliana Jones',2000),
	(N'Paulo Cunha',1000),
	(N'Estela Moura',8000),
	(N'Andy Gonzalez',23000),
	(N'Mia Rose',8000),
	(N'Pimpinha Jardim',15000),
	(N'Abilio Curto',5000),
	(N'Holly Molly',900),
	(N'Antonieta Padilha',800),
	(N'Paulo Boavida',700),
	(N'Bob Esponja',12000),
	(N'Brigite Bardot',5000),
	(N'Bruna Castro',1000),
	(N'Ciro Gomes',20000),
	(N'Cheila Pereira',90000),
	(N'Quintino Aires',9000),
	(N'Chico Esperto',50),
	(N'Mister Kaizer',800000),
	(N'João Félix',1000000),
	(N'Santana Lopes',500000),
	(N'Damião Taveira',1000),
	(N'Eliseu Antunes',3000),
	(N'Horácio Moura',6000),
	(N'Eduardo Valério',10000),
	(N'João Sousa',550000),
	(N'Pablo Aimar',2000000),
	(N'Vladimir Pudim',5000000),
	(N'Wally Wally',9999999),
	(N'Lebron James',6666993),
	(N'Bruno Lage',250000),
	(N'Sérgio Conceição',156000),
	(N'Donald Trump',5500666),
	(N'Tio Patinhas',20000000),
	(N'Bruno Fernandes',2500000),
	(N'Paulo Futre',99999),
	(N'Joaquim das Couves',2000),
	(N'Bas Dost',88888),
	(N'Gary Neville',50000),
	(N'Luís Filipe Vieira',3000000),
	(N'Pinto da Costa',9000888),
	(N'Bruno de Carvalho',10000001),
	(N'Manuel Vilarinho',66666),
	(N'Manuela Moura Guedes',99999),
	(N'Iker Casillas',33333),
	(N'Sara Carbonero',55555),
	(N'Moussa Marega',1110),
	(N'Dolores Aveiro',20000),
	(N'Van Gog',2000),
	(N'Marco Horácio',500),
	(N'Salvador Daqui',660),
	(N'Salvador Dali',880),
	(N'Vítor Baía',990),
	(N'Rúben Dias',10000),
	(N'Marisa Matias',35000),
	(N'Catarina Furtado',8000),
	(N'António Guterres',90000),
	(N'José Mourinho',600000),
	(N'Claúdio Ramos',600),
	(N'José Rocha',50000),
	(N'André The Giant',5000),
	(N'Hulk Hogan',7000),
	(N'Roman Reigns',8000),
	(N'Tomé Estrela',550),
	(N'Miguel Ângelo',990),
	(N'Lewis Hamilton',940),
	(N'Alan Prost',920),
	(N'Didier Drogba',1000),
	(N'Didier Deschamps',1000),
	(N'Giorgina Rodriguez',4444440),
	(N'Norberto Santos',1000),
	(N'Michael Shumacher',2000),
	(N'David Couthard',4400),
	(N'Pedro Lamy',5550),
	(N'Tiago Monteiro',880),
	(N'Ana Banana',770),
	(N'Baltasar Batata',6000),
	(N'Valentim Loureiro',160),
	(N'Xavier Bolota',3000),
	(N'Bobby Lashley',220),
	(N'Jonh Cena',550),
	(N'Pedro Gonçalves',990),
	(N'Pedro Atum',880),
	(N'Alfredo Vilela',770),
	(N'Miguel Albuquerque',720),
	(N'Joana Salmão',560),
	(N'Elma Aveiro',1110),
	(N'Eliana Marques',9990),
	(N'Fernando Faria',4440),
	(N'Paloma Reis',5550),
	(N'Vitor Pontes',8880),
	(N'Raimundo Mendonça',77990),
	(N'Jorge Sampaio',9960),
	(N'Alexandra Solnado',1960),
	(N'Madalena Iglésias',2860),
	(N'Giorgio Armani',2850),
	(N'Roberto Leal',6300),
	(N'Joana Espirito Santo',3600),
	(N'Lua Eanes',990),
	(N'Violeta Aguiar',880),
	(N'Papa Xico',7650),
	(N'Eduardo Mendes',6590),
	(N'Luigi Ferrari',5480),
	(N'Madonna',10000),
	(N'Inês Guedes',20000),
	(N'Helena Herédia',6330),
	(N'Virgilio Faria',4440),
	(N'Elton Jonh',5540),
	(N'Galileu Galilei',5540),
	(N'Valter Pinho',1150),
	(N'Carlos Moniz',7650),
	(N'Pedro Morgado',5540),
	(N'Raul Monteiro',1650),
	(N'Jim Carrey',1980),
	(N'Mateus Oliveira',1570),
	(N'Gisela Serrano',1470),
	(N'Teresa Sousa',1320),
	(N'Filipe Cunha',1020),
	(N'Nádia Navratilova',1860),
	(N'Marcelo Ribas',7980),
	(N'Simão Garcia',10550),
	(N'Lúcia Freire',77990),
	(N'Licinio Seixas',100000),
	(N'Roberta Miranda',90000),
	(N'Ramiro Matias',9000000),
	(N'António de Oliveira Salazar',1450),
	(N'Lígia Serpa',4560),
	(N'Sebastião Medeiros',8000),
	(N'João Marçal',9000),
	(N'Filomena Ferreira',7770),
	(N'Fátima Costa',7170),
	(N'Margarida Fialho',8880),
	(N'Teófilo Esteves',9970),
	(N'Xi Jimping',8870),
	(N'Sabrina Isidoro',7790),
	(N'Mike Pompeo',8880),
	(N'Romeu Ribeiro',2000),
	(N'Martin Luther King',9990),
	(N'Artur Agostinho',4660),
	(N'Vânia Figueira',8770),
	(N'Alexa Bliss',7770),
	(N'Natália Albuquerque',70000),
	(N'Conde Vladimir',800000),
	(N'O Monstro das Bolachas',80000),
	(N'Urbano Lage',20000),
	(N'Vera Fernandes',10000),
	(N'Gil Jiménez',77890),
	(N'Alexandre Fagundes',3000),
	(N'Valdemar Brito',300),
	(N'Carlos Alberto Moniz',72000),
	(N'Anna Kournikova',9820),
	(N'Randy Orton',7100),
	(N'Jorge Andrade',9630),
	(N'Francisco Guerra',3180),
	(N'Triple HHH',5490),
	(N'The Rock',6320),
	(N'Egídio Lopes',8790),
	(N'Ana Gomes',1000),
	(N'Maria João Costa',52000),
	(N'Fábio Soares',5000),
	(N'Albertino Vieira',9000),
	(N'Filipa Vilaça',1170),
	(N'Jerónimo Ochoa',770),
	(N'Bruno Aleixo',7770),
	(N'Nuno Markl',8880),
	(N'Vince McMahon',8890),
	(N'Nuno Assis',9940),
	(N'António Monteiro',1000),
	(N'Carmina Burana',20000),
	(N'Henrique Vilar',9000),
	(N'Vasco Gameiro',900010),
	(N'Flávio Azevedo',1120),
	(N'Nicolas Castilho',778),
	(N'Armando Gama',4576),
	(N'Diogo Morgado',120399),
	(N'Yolanda Coelho',3443435),
	(N'Wilson Borba',545515),
	(N'Sofia Arruda',99885),
	(N'Enrique Iglésias',945189),
	(N'Tozé Marreco',91951),
	(N'Alberto João Jardim',61511),
	(N'José Alberto',98495151),
	(N'Sónia Santos',61595915),
	(N'Cristina Ferreira',91195195),
	(N'Rui Rio',951951),
	(N'Quim Barreiros',191919),
	(N'Cinha Jardim',87878),
	(N'Henrique Feist',519190),
	(N'Leonardo Davintes',9844949)
GO
/*
*Insert's tabela desconto
*/
INSERT [dbo].[desconto]([desc_id],[milhas_min],[milhas_max],[perc_desc]) VALUES 
	(1,1000,1999,1),
	(2,2000,2999,2),
	(3,3000,3999,3),
	(4,4000,4999,4),
	(5,5000,5999,5),
	(6,6000,6999,6),
	(7,7000,7999,7),
	(8,8000,8999,8),
	(9,9000,9999,9),
	(10,10000,10999,10),
	(11,11000,11999,12),
	(12,12000,12999,14),
	(13,13000,13999,16),
	(14,14000,14999,18),
	(15,15000,15999,20),
	(16,16000,16999,22),
	(17,17000,17999,24),
	(18,18000,18999,26),
	(19,19000,19999,28),
	(20,20000,22499,30),
	(21,22500,24999,33),
	(22,25000,27499,36),
	(23,27500,29999,39),
	(24,30000,49999,42),
	(25,50000,99999,45),
	(26,100000,199999,50),
	(27,200000,499999,55),
	(28,500000,999999,60),
	(29,1000000,4999999,70),
	(30,5000000,9223372036854775807,80)
GO
/*
*Insert's tabela voo
*/
INSERT [dbo].[voo]([voo_dur],[voo_data],[voo_part],[voo_dest],[preco_base],[dist_milhas],[av_id]) VALUES 
	('05:00:00','2019-08-19 13:00:00',N'Lisboa,Portugal',N'Nova Iorque,EUA',1500,3372,1),
	('03:00:00','2019-08-20 13:00:00',N'Rio de Janeiro,Brasil',N'Fortaleza,Brasil',800,1363,1),
	('06:30:00','2019-08-21 13:00:00',N'Pequim,China',N'Detroit,EUA',2000,5869,2),
	('02:00:00','2019-08-22 13:00:00',N'Tóquio,Japão',N'Vancouver,Canadá',2500,4698,3),
	('02:30:00','2019-08-23 13:00:00',N'La Paz,México',N'Caracas,Venezuela',1200,2999,4),
	('04:00:00','2019-08-24 13:00:00',N'Lisboa,Portugal',N'Berlim,Alemanha',600,1438,5),
	('03:00:00','2019-08-25 13:00:00',N'Lisboa,Portugal',N'Paris,França',400,903,6),
	('04:30:00','2019-08-26 13:00:00',N'Lisboa,Portugal',N'São Petersburgo,Rússia',1500,2249,7),
	('00:30:00','2019-08-27 13:00:00',N'Lisboa,Portugal',N'Faro,Portugal',150,172,8),
	('01:00:00','2019-08-28 13:00:00',N'Lisboa,Portugal',N'Funchal,Portugal',350,605,9),
	('02:00:00','2019-08-29 13:00:00',N'Londres,Reino Unido',N'São Miguel,Portugal',950,1555,10),
	('03:00:00','2019-08-30 13:00:00',N'Lisboa,Portugal',N'Varsóvia,Polónia',800,1716,11),
	('04:00:00','2019-09-01 10:00:00',N'Moscovo,Rússia',N'Madrid,Espanha',1250,2805,12),
	('05:00:00','2019-09-01 18:00:00',N'Osaka,Japão',N'Jacarta,Indonésia',1300,3390,13),
	('06:00:00','2019-09-02 10:00:00',N'Buenos Aires,Argentina',N'Barcelona,Espanha',1400,6509,14),
	('07:30:00','2019-09-02 18:00:00',N'Santiago,Chile',N'Paris,França',1500,7245,15),
	('05:00:00','2019-09-03 10:00:00',N'Dublin,Irlanda',N'Boston,EUA',1100,2991,16),
	('04:00:00','2019-09-03 18:00:00',N'São Miguel,Portugal',N'Nova York,EUA',1250,2572,17),
	('03:00:00','2019-09-04 10:00:00',N'Porto,Portugal',N'Roma,Itália',800,1091,18),
	('02:00:00','2019-09-04 18:00:00',N'Los Angeles,EUA',N'Portland,EUA',750,827,19),
	('02:00:00','2019-09-05 10:00:00',N'Istambul,Turquia',N'Atenas,Grécia',450,349,20),
	('02:00:00','2019-09-05 18:00:00',N'Helsinquia,Finlândia',N'Estocolmo,Suécia',400,298,1),
	('04:00:00','2019-09-06 10:00:00',N'Porto,Portugal',N'Praia,Cabo Verde',800,2021,2),
	('03:00:00','2019-09-06 18:00:00',N'Toronto,Canadá',N'Edmonton,Canadá',750,1683,3),
	('01:30:00','2019-09-07 10:00:00',N'Lisboa,Portugal',N'Nova York,EUA',1350,3372,4),
	('05:30:00','2019-09-07 18:00:00',N'Sydney,Austrália',N'Auckland,Nova Zelândia',1500,1341,5),
	('03:30:00','2019-09-08 10:00:00',N'Lisboa,Portugal',N'Atenas,Grécia',500,1773,6),
	('04:30:00','2019-09-08 18:00:00',N'Madrid,Espanha',N'Cairo,Egito',950,2083,7),
	('02:00:00','2019-09-09 10:00:00',N'Camberra,Austrália',N'Sydney,Austrália',400,177,8),
	('02:00:00','2019-09-09 18:00:00',N'Calgary,Canadá',N'Toronto,Canadá',1200,1686,9),
	('02:00:00','2019-09-10 10:00:00',N'Mascate,Omã',N'Abu Dhabi,EAU',550,262,10),
	('02:00:00','2019-09-10 18:00:00',N'Split,Croácia',N'Salzburgo,Áustria',450,339,11),
	('02:00:00','2019-09-11 10:00:00',N'Nuremberga,Alemanha',N'Amesterdão,Holanda',650,337,12),
	('03:00:00','2019-09-11 18:00:00',N'Manchester,Reino Unido',N'Copenhaga,Dinamarca',850,611,13),
	('04:00:00','2019-09-12 10:00:00',N'Luanda,Angola',N'Cairo,Egito',1700,2943,14),
	('02:00:00','2019-09-12 18:00:00',N'Lisboa,Portugal',N'Barcelona,Espanha',500,626,15),
	('02:00:00','2019-09-13 10:00:00',N'Barcelona,Espanha',N'Porto,Portugal',400,561,16),
	('02:00:00','2019-09-13 18:00:00',N'São Miguel,Portugal',N'Dublin,Irlanda',950,1414,17),
	('01:00:00','2019-09-14 10:00:00',N'Lisboa,Portugal',N'Porto,Portugal',150,194,18),
	('04:00:00','2019-09-14 18:00:00',N'Yakutsk,Rússia',N'San Diego,EUA',3500,4924,19),
	('06:00:00','2019-09-15 10:00:00',N'Kiev,Ucrânia',N'Barcelona,Espanha',1000,1489,20),
	('07:00:00','2019-09-15 18:00:00',N'Keflavik,Islândia',N'Ancara,Turquia',2000,4572,1),
	('08:00:00','2019-09-16 10:00:00',N'Cidade do Cabo,África do Sul',N'Nova York,EUA',5000,7814,2),
	('04:00:00','2019-09-16 18:00:00',N'Larnaca,Chipre',N'Saransk,Rússia',1200,1445,3),
	('02:00:00','2019-09-17 12:00:00',N'Moscovo,Rússia',N'Baku,Azerbaijão',2500,4191,4),
	('02:00:00','2019-09-18 12:00:00',N'Riga,Letónia',N'Oslo,Noruega',800,524,5),
	('02:00:00','2019-09-19 12:00:00',N'Varsóvia,Polónia',N'Berlim,Alemanha',400,322,6),
	('02:00:00','2019-09-20 12:00:00',N'Lisboa,Portugal',N'Barcelona,Espanha',500,626,7),
	('01:00:00','2019-09-21 12:00:00',N'Porto,Portugal',N'Lisboa,Portugal',150,194,8),
	('03:00:00','2019-09-22 12:00:00',N'Vancouver,Canadá',N'Chicago,EUA',1500,1773,9)
GO
/*
*Insert's tabela escala
*/
INSERT [dbo].[escala]([esc_data_ini],[esc_data_fim],[voo_id]) VALUES 
	('2019-08-19 13:00:00','2019-08-19 18:00:00',1),
	('2019-08-20 13:00:00','2019-08-20 16:00:00',2),
	('2019-08-21 13:00:00','2019-08-21 19:30:00',3),
	('2019-08-22 13:00:00','2019-08-22 15:00:00',4),
	('2019-08-23 13:00:00','2019-08-23 15:30:00',5),
	('2019-08-24 13:00:00','2019-08-24 17:00:00',6),
	('2019-08-25 13:00:00','2019-08-25 16:00:00',7),
	('2019-08-26 13:00:00','2019-08-26 17:30:00',8),
	('2019-08-27 13:00:00','2019-08-27 13:30:00',9),
	('2019-08-28 13:00:00','2019-08-28 14:00:00',10),
	('2019-08-29 13:00:00','2019-08-29 15:00:00',11),
	('2019-08-30 13:00:00','2019-08-30 16:00:00',12),
	('2019-09-01 10:00:00','2019-09-01 14:00:00',13),
	('2019-09-01 18:00:00','2019-09-01 23:00:00',14),
	('2019-09-02 10:00:00','2019-09-02 16:00:00',15),
	('2019-09-02 18:00:00','2019-09-03 01:30:00',16),
	('2019-09-03 10:00:00','2019-09-03 15:00:00',17),
	('2019-09-03 18:00:00','2019-09-03 22:00:00',18),
	('2019-09-04 10:00:00','2019-09-04 13:00:00',19),
	('2019-09-04 18:00:00','2019-09-04 20:00:00',20),
	('2019-09-05 10:00:00','2019-09-05 12:00:00',21),
	('2019-09-05 18:00:00','2019-09-05 20:00:00',22),
	('2019-09-06 10:00:00','2019-09-06 14:00:00',23),
	('2019-09-06 18:00:00','2019-09-06 21:00:00',24),
	('2019-09-07 10:00:00','2019-09-07 11:30:00',25),
	('2019-09-07 18:00:00','2019-09-07 23:30:00',26),
	('2019-09-08 10:00:00','2019-09-08 13:30:00',27),
	('2019-09-08 18:00:00','2019-09-08 22:30:00',28),
	('2019-09-09 10:00:00','2019-09-09 12:00:00',29),
	('2019-09-09 18:00:00','2019-09-09 20:00:00',30),
	('2019-09-10 10:00:00','2019-09-10 12:00:00',31),
	('2019-09-10 18:00:00','2019-09-10 20:00:00',32),
	('2019-09-11 10:00:00','2019-09-11 12:00:00',33),
	('2019-09-11 18:00:00','2019-09-11 21:00:00',34),
	('2019-09-12 10:00:00','2019-09-12 14:00:00',35),
	('2019-09-12 18:00:00','2019-09-12 20:00:00',36),
	('2019-09-13 10:00:00','2019-09-13 12:00:00',37),
	('2019-09-13 18:00:00','2019-09-13 20:00:00',38),
	('2019-09-14 10:00:00','2019-09-14 11:00:00',39),
	('2019-09-14 18:00:00','2019-09-14 22:00:00',40),
	('2019-09-15 10:00:00','2019-09-15 16:00:00',41),
	('2019-09-15 18:00:00','2019-09-16 01:00:00',42),
	('2019-09-16 10:00:00','2019-09-16 18:00:00',43),
	('2019-09-16 18:00:00','2019-09-16 22:00:00',44),
	('2019-09-17 12:00:00','2019-09-17 14:00:00',45),
	('2019-09-18 12:00:00','2019-09-18 14:00:00',46),
	('2019-09-19 12:00:00','2019-09-19 14:00:00',47),
	('2019-09-20 12:00:00','2019-09-20 14:00:00',48),
	('2019-09-21 12:00:00','2019-09-21 13:00:00',49),
	('2019-09-22 12:00:00','2019-09-22 15:00:00',50)
GO
/*
*Insert's tabela funcionario
*/
INSERT [dbo].[funcionario]([func_nome],[func_tipo],[esc_id]) VALUES
	(N'João Sousa',N'Tripulação',1),
	(N'Laura Rebelo',N'Tripulação',1),
	(N'Neymar Junior',N'Tripulação',2),
	(N'Leonel Messi',N'Tripulação',2),
	(N'Joaquim Simões',N'Tripulação',3),
	(N'Pedro Silvestre',N'Tripulação',3),
	(N'Mariana Valente',N'Tripulação',4),
	(N'Mário Morgado',N'Tripulação',4),
	(N'Vitor Veloso',N'Tripulação',5),
	(N'Vasco Vasconcelos',N'Tripulação',5),
	(N'Valentim Loureiro',N'Tripulação',6),
	(N'José Ramos',N'Tripulação',6),
	(N'João Costa',N'Tripulação',7),
	(N'Ana Sousa',N'Tripulação',7),
	(N'Olívia Trindade',N'Tripulação',8),
	(N'Pedro Sobral',N'Tripulação',8),
	(N'Nádia Navratilova',N'Tripulação',9),
	(N'Mários Soares',N'Tripulação',9),
	(N'Emanuel Macron',N'Tripulação',10),
	(N'Vanda Sintra',N'Tripulação',10),
	(N'Sónia Santos',N'Tripulação',11),
	(N'Renato Duarte',N'Tripulação',11),
	(N'Ricardo Pantera',N'Tripulação',12),
	(N'Mateus Quinta',N'Tripulação',12),
	(N'Quintino Aires',N'Tripulação',13),
	(N'Cristina Ribas',N'Tripulação',13),
	(N'Pedro Ramos',N'Tripulação',14),
	(N'Joana Jacinto',N'Tripulação',14),
	(N'Inês Paixão',N'Tripulação',15),
	(N'Sílvia Ourique',N'Tripulação',15),
	(N'Helena Mendonça',N'Tripulação',16),
	(N'João Medina',N'Tripulação',16),
	(N'Elton Rúbio',N'Tripulação',17),
	(N'Elma Aveiro',N'Tripulação',17),
	(N'Vera Melo',N'Tripulação',18),
	(N'Diana Meira',N'Tripulação',18),
	(N'José Esteves',N'Tripulação',19),
	(N'Rosa Mesquita',N'Tripulação',19),
	(N'David Pacheco',N'Tripulação',20),
	(N'Daniel Madureira',N'Tripulação',20),
	(N'Celina Jesus',N'Tripulação',21),
	(N'João Lago',N'Tripulação',21),
	(N'Isidoro Zarco',N'Tripulação',22),
	(N'Celso Guimarães',N'Tripulação',22),
	(N'Vanda Gusmão',N'Tripulação',23),
	(N'Pedro Mantorras',N'Tripulação',23),
	(N'Ana Marques',N'Tripulação',24),
	(N'Joana Galvão',N'Tripulação',24),
	(N'Baltasar Rocha',N'Tripulação',25),
	(N'Amanda Freitas',N'Tripulação',25),
	(N'Amélia Durão',N'Tripulação',26),
	(N'Abílio Sousa',N'Tripulação',26),
	(N'Paulo Domingos',N'Tripulação',27),
	(N'Anabela Faro',N'Tripulação',27),
	(N'Samantha Craveiro',N'Tripulação',28),
	(N'Cristiana Alberto',N'Tripulação',28),
	(N'Sílvia Romero',N'Tripulação',29),
	(N'Jerónimo Cunha',N'Tripulação',29),
	(N'Inês Palmeiro',N'Tripulação',30),
	(N'João Sobral',N'Tripulação',30),
	(N'Carlos Mendonça',N'Tripulação',31),
	(N'Lucas Infantino',N'Tripulação',31),
	(N'Rudy Gobert',N'Tripulação',32),
	(N'Zeferino Lopes',N'Tripulação',32),
	(N'Jack Jonhson',N'Tripulação',33),
	(N'Dina Aguiar',N'Tripulação',33),
	(N'Golias Abreu',N'Tripulação',34),
	(N'Rui Craveiro',N'Tripulação',34),
	(N'Michael Resende',N'Tripulação',35),
	(N'Daniel Silva',N'Tripulação',35),
	(N'Catarina Platini',N'Tripulação',36),
	(N'Manuel Gião',N'Tripulação',36),
	(N'Gianni Landim',N'Tripulação',37),
	(N'Henrique Faro',N'Tripulação',37),
	(N'Vanessa Miranda',N'Tripulação',38),
	(N'Xanana Gusmão',N'Tripulação',38),
	(N'António Oliveira',N'Tripulação',39),
	(N'Didier Drogba',N'Tripulação',39),
	(N'Éder Lopes',N'Tripulação',40),
	(N'Gonçalo Guedes',N'Tripulação',40),
	(N'Artur Agostinho',N'Tripulação',41),
	(N'Durão Barroso',N'Tripulação',41),
	(N'Manuel Queiroz',N'Tripulação',42),
	(N'Domingos Andrade',N'Tripulação',42),
	(N'Susana Santos',N'Tripulação',43),
	(N'Soraia Dragão',N'Tripulação',43),
	(N'Francisco Índia',N'Tripulação',44),
	(N'Paulo Guerra',N'Tripulação',44),
	(N'Jalamed Tarrafal',N'Tripulação',45),
	(N'Albertino Guardiola',N'Tripulação',45),
	(N'Bárbara Bandeira',N'Tripulação',46),
	(N'Viktor Orban',N'Tripulação',46),
	(N'Michelle Obama',N'Tripulação',47),
	(N'Pedro Lamy',N'Tripulação',47),
	(N'Junior Kane',N'Tripulação',48),
	(N'José Fonte',N'Tripulação',48),
	(N'Homero Silva',N'Tripulação',49),
	(N'Ana Akmed',N'Tripulação',49),
	(N'Pedro Coelho',N'Tripulação',50),
	(N'Sónia Araújo',N'Tripulação',50),
	(N'Teresa Sousa',N'Assistente de Embarque',null),
	(N'Judite Resende',N'Assistente de Embarque',null),
	(N'João Rebelo',N'Assistente de Embarque',null),
	(N'Carlos Osório',N'Assistente de Embarque',null),
	(N'Graça Meireles',N'Assistente de Embarque',null),
	(N'Jorge Madeira',N'Assistente de Embarque',null),
	(N'César Augusto',N'Assistente de Embarque',null),
	(N'Benjamim Guedes',N'Assistente de Embarque',null),
	(N'Gil Gomes',N'Assistente de Embarque',null),
	(N'Catarina Freixo',N'Assistente de Embarque',null),
	(N'Dinis Liberato',N'Assistente de Embarque',null),
	(N'Cristiano Ronaldo',N'Apoio Administrativo',null),
	(N'Beatriz Rocha',N'Apoio Administrativo',null),
	(N'António Salgueiro',N'Apoio Administrativo',null),
	(N'Marta Torres',N'Apoio Administrativo',null),
	(N'Maria Valério',N'Apoio Administrativo',null),
	(N'Miguel Viana',N'Apoio Administrativo',null),
	(N'Carla Rocha',N'Apoio Administrativo',null),
	(N'Bárbara Andrade',N'Apoio Administrativo',null),
	(N'Juvenal Malheiro',N'Apoio Administrativo',null)
GO
/*
*Insert's tabela reserva
*/
INSERT [dbo].[reserva]([bilhete_emitido],[res_data],[voo_id],[pass_id],[ref_id],[preco_extras]) VALUES
	(N'S','2019-05-01 11:00:00',1,1,1,0),
	(N'S','2019-05-01 11:00:00',1,2,2,0),
	(N'S','2019-05-01 11:00:00',1,3,3,0),
	(N'S','2019-05-01 11:00:00',1,4,1,0),
	(N'S','2019-05-01 11:00:00',1,5,2,0),
	(N'S','2019-05-01 11:00:00',1,6,3,100),
	(N'S','2019-05-01 11:00:00',1,7,1,0),
	(N'S','2019-05-01 11:00:00',1,8,2,0),
	(N'S','2019-05-01 11:00:00',1,9,3,0),
	(N'S','2019-05-01 11:00:00',1,10,1,0),
	(N'S','2019-05-01 11:00:00',1,11,2,0),
	(N'S','2019-05-01 11:00:00',1,12,3,0),
	(N'S','2019-05-01 11:00:00',1,13,1,0),
	(N'S','2019-05-01 11:00:00',1,14,2,0),
	(N'S','2019-05-01 11:00:00',1,15,3,0),
	(N'S','2019-05-01 11:00:00',1,16,1,0),
	(N'S','2019-05-01 11:00:00',1,17,2,0),
	(N'S','2019-05-01 11:00:00',1,18,2,80),
	(N'S','2019-05-01 11:00:00',1,19,1,0),
	(N'S','2019-05-01 11:00:00',1,20,2,0),
	(N'S','2019-05-01 11:00:00',1,21,3,0),
	(N'S','2019-05-01 11:00:00',1,22,1,0),
	(N'S','2019-05-01 11:00:00',1,23,2,0),
	(N'S','2019-05-01 11:00:00',1,24,3,200),
	(N'S','2019-05-01 11:00:00',1,25,1,150),
	(N'S','2019-05-01 11:00:00',1,26,2,0),
	(N'S','2019-05-01 11:00:00',1,27,3,0),
	(N'S','2019-05-01 11:00:00',1,28,1,0),
	(N'S','2019-05-01 11:00:00',1,29,2,0),
	(N'S','2019-05-01 11:00:00',1,30,3,0),
	(N'S','2019-05-01 11:00:00',1,31,1,0),
	(N'S','2019-05-01 11:00:00',1,32,2,0),
	(N'S','2019-05-01 11:00:00',1,33,3,0),
	(N'S','2019-05-01 11:00:00',1,34,1,0),
	(N'S','2019-05-01 11:00:00',1,35,2,0),
	(N'S','2019-05-01 11:00:00',1,36,3,0),
	(N'S','2019-05-01 11:00:00',1,37,1,0),
	(N'S','2019-05-01 11:00:00',1,38,2,0),
	(N'S','2019-05-01 11:00:00',1,39,3,0),
	(N'S','2019-05-01 11:00:00',1,40,1,0),
	(N'S','2019-05-01 11:00:00',1,41,2,0),
	(N'S','2019-05-01 11:00:00',1,42,3,0),
	(N'S','2019-05-01 11:00:00',1,43,1,0),
	(N'S','2019-05-01 11:00:00',1,44,2,0),
	(N'S','2019-05-01 11:00:00',1,45,3,0),
	(N'S','2019-05-01 11:00:00',1,46,1,0),
	(N'S','2019-05-01 11:00:00',1,47,2,0),
	(N'S','2019-05-01 11:00:00',1,48,1,0),
	(N'S','2019-05-01 11:00:00',1,49,3,0),
	(N'S','2019-05-01 11:00:00',1,50,1,0),
	(N'S','2019-05-01 11:00:00',1,51,2,0),
	(N'S','2019-05-01 11:00:00',1,52,1,0),
	(N'S','2019-05-01 11:00:00',1,53,3,0),
	(N'S','2019-05-01 11:00:00',1,54,1,0),
	(N'S','2019-05-01 11:00:00',1,55,2,0),
	(N'S','2019-05-01 11:00:00',1,56,1,0),
	(N'S','2019-05-01 11:00:00',1,57,3,0),
	(N'S','2019-05-01 11:00:00',1,58,1,0),
	(N'S','2019-05-01 11:00:00',1,59,2,0),
	(N'S','2019-05-01 11:00:00',1,60,1,0),
	(N'S','2019-05-01 11:00:00',1,61,3,0),
	(N'S','2019-05-01 11:00:00',1,62,1,0),
	(N'S','2019-05-01 11:00:00',1,63,2,0),
	(N'S','2019-05-01 11:00:00',1,64,1,0),
	(N'S','2019-05-01 11:00:00',1,65,3,0),
	(N'S','2019-05-01 11:00:00',1,66,1,0),
	(N'S','2019-05-01 11:00:00',1,67,2,0),
	(N'S','2019-05-01 11:00:00',1,68,1,0),
	(N'S','2019-05-01 11:00:00',1,69,3,0),
	(N'S','2019-05-01 11:00:00',1,70,1,0),
	(N'S','2019-05-01 11:00:00',1,71,2,0),
	(N'S','2019-05-01 11:00:00',1,72,1,0),
	(N'S','2019-05-01 11:00:00',1,73,3,0),
	(N'S','2019-05-01 11:00:00',1,74,1,0),
	(N'S','2019-05-01 11:00:00',1,75,2,0),
	(N'S','2019-05-01 11:00:00',1,76,1,0),
	(N'S','2019-05-01 11:00:00',1,77,3,0),
	(N'S','2019-05-01 11:00:00',1,78,1,0),
	(N'S','2019-05-01 11:00:00',1,79,2,0),
	(N'S','2019-05-01 11:00:00',1,80,1,0),
	(N'S','2019-05-01 11:00:00',2,81,3,0),
	(N'S','2019-05-01 11:00:00',3,82,1,0),
	(N'S','2019-05-01 11:00:00',4,83,null,0),
	(N'S','2019-05-01 11:00:00',5,84,1,0),
	(N'S','2019-05-01 11:00:00',5,85,3,0),
	(N'S','2019-05-01 11:00:00',6,86,1,0),
	(N'S','2019-05-01 11:00:00',6,87,2,0),
	(N'S','2019-05-01 11:00:00',6,88,1,0),
	(N'S','2019-05-01 11:00:00',6,89,3,0),
	(N'S','2019-05-01 11:00:00',6,90,1,0),
	(N'S','2019-05-01 11:00:00',6,91,2,0),
	(N'S','2019-05-01 11:00:00',6,92,1,0),
	(N'S','2019-05-01 11:00:00',7,93,3,0),
	(N'S','2019-05-01 11:00:00',7,94,1,0),
	(N'S','2019-05-01 11:00:00',7,95,2,0),
	(N'S','2019-05-01 11:00:00',7,96,1,250),
	(N'S','2019-05-01 11:00:00',7,97,3,0),
	(N'S','2019-05-01 11:00:00',7,98,1,0),
	(N'S','2019-05-01 11:00:00',7,99,2,0),
	(N'S','2019-05-01 11:00:00',7,100,1,0),
	(N'S','2019-05-01 11:00:00',8,101,3,0),
	(N'S','2019-05-01 11:00:00',8,102,1,0),
	(N'S','2019-05-01 11:00:00',8,103,2,0),
	(N'S','2019-05-01 11:00:00',8,104,1,0),
	(N'S','2019-05-01 11:00:00',8,105,3,0),
	(N'S','2019-05-01 11:00:00',8,106,1,0),
	(N'S','2019-05-01 11:00:00',9,107,null,0),
	(N'S','2019-05-01 11:00:00',9,108,null,0),
	(N'S','2019-05-01 11:00:00',9,109,null,0),
	(N'S','2019-05-01 11:00:00',10,110,null,0),
	(N'S','2019-05-01 11:00:00',10,111,null,0),
	(N'S','2019-05-01 11:00:00',10,112,null,0),
	(N'S','2019-05-01 11:00:00',10,113,null,0),
	(N'S','2019-05-01 11:00:00',11,114,null,0),
	(N'S','2019-05-01 11:00:00',11,115,null,0),
	(N'S','2019-05-01 11:00:00',11,116,null,0),
	(N'S','2019-05-01 11:00:00',11,117,null,0),
	(N'S','2019-05-01 11:00:00',12,118,2,0),
	(N'S','2019-05-01 11:00:00',12,119,1,0),
	(N'S','2019-05-01 11:00:00',12,120,2,0),
	(N'S','2019-05-01 11:00:00',12,121,1,0),
	(N'S','2019-05-01 11:00:00',13,122,1,0),
	(N'S','2019-05-01 11:00:00',13,123,1,0),
	(N'S','2019-05-01 11:00:00',13,124,2,0),
	(N'S','2019-05-01 11:00:00',13,125,1,0),
	(N'S','2019-05-01 11:00:00',14,126,1,0),
	(N'S','2019-05-01 11:00:00',14,127,3,0),
	(N'S','2019-05-01 11:00:00',14,128,1,0),
	(N'S','2019-05-01 11:00:00',14,129,2,20),
	(N'S','2019-05-01 11:00:00',14,130,1,100),
	(N'S','2019-05-01 11:00:00',14,131,1,50),
	(N'S','2019-05-01 11:00:00',15,132,3,60),
	(N'S','2019-05-01 11:00:00',15,133,1,400),
	(N'S','2019-05-01 11:00:00',15,134,2,90),
	(N'S','2019-05-01 11:00:00',15,135,1,0),
	(N'S','2019-05-01 11:00:00',16,136,3,0),
	(N'S','2019-05-01 11:00:00',16,137,1,0),
	(N'S','2019-05-01 11:00:00',17,138,1,0),
	(N'S','2019-05-01 11:00:00',17,139,1,0),
	(N'S','2019-05-01 11:00:00',18,140,2,0),
	(N'S','2019-05-01 11:00:00',18,141,1,0),
	(N'S','2019-05-01 11:00:00',18,142,3,0),
	(N'S','2019-05-01 11:00:00',19,143,1,0),
	(N'S','2019-05-01 11:00:00',20,144,null,0),
	(N'S','2019-05-01 11:00:00',22,145,null,0),
	(N'S','2019-05-01 11:00:00',23,146,1,0),
	(N'S','2019-05-01 11:00:00',24,147,1,0),
	(N'S','2019-05-01 11:00:00',25,148,null,0),
	(N'S','2019-05-01 11:00:00',26,149,1,0),
	(N'S','2019-05-01 11:00:00',27,150,1,0),
	(N'S','2019-05-01 11:00:00',28,151,2,0),
	(N'S','2019-05-01 11:00:00',29,152,null,0),
	(N'S','2019-05-01 11:00:00',30,153,null,0),
	(N'S','2019-05-01 11:00:00',31,154,null,0),
	(N'S','2019-05-01 11:00:00',32,155,null,0),
	(N'S','2019-05-01 11:00:00',33,156,null,0),
	(N'S','2019-05-01 11:00:00',34,157,1,0),
	(N'S','2019-05-01 11:00:00',34,158,3,0),
	(N'S','2019-05-01 11:00:00',34,159,2,0),
	(N'S','2019-05-01 11:00:00',35,160,3,0),
	(N'S','2019-05-01 11:00:00',35,161,1,0),
	(N'S','2019-05-01 11:00:00',36,162,null,0),
	(N'S','2019-05-01 11:00:00',36,163,null,0),
	(N'S','2019-05-01 11:00:00',37,164,null,0),
	(N'S','2019-05-01 11:00:00',38,165,null,0),
	(N'S','2019-05-01 11:00:00',39,166,null,0),
	(N'S','2019-05-01 11:00:00',40,167,1,0),
	(N'S','2019-05-01 11:00:00',41,168,1,0),
	(N'S','2019-05-01 11:00:00',41,169,1,0),
	(N'S','2019-05-01 11:00:00',41,170,1,0),
	(N'S','2019-05-01 11:00:00',41,171,1,0),
	(N'S','2019-05-01 11:00:00',41,172,1,0),
	(N'S','2019-05-01 11:00:00',41,173,1,40),
	(N'S','2019-05-01 11:00:00',41,174,1,0),
	(N'S','2019-05-01 11:00:00',41,175,1,0),
	(N'S','2019-05-01 11:00:00',41,176,1,0),
	(N'S','2019-05-01 11:00:00',41,177,1,0),
	(N'S','2019-05-01 11:00:00',41,178,1,0),
	(N'S','2019-05-01 11:00:00',42,179,1,0),
	(N'S','2019-05-01 11:00:00',43,180,1,0),
	(N'S','2019-05-01 11:00:00',44,181,1,0),
	(N'S','2019-05-01 11:00:00',45,182,null,0),
	(N'S','2019-05-01 11:00:00',46,183,null,0),
	(N'S','2019-05-01 11:00:00',47,184,null,0),
	(N'S','2019-05-01 11:00:00',47,185,null,0),
	(N'S','2019-05-01 11:00:00',47,186,null,0),
	(N'S','2019-05-01 11:00:00',47,187,null,0),
	(N'S','2019-05-01 11:00:00',48,188,null,0),
	(N'S','2019-05-01 11:00:00',48,189,null,0),
	(N'S','2019-05-01 11:00:00',48,190,null,0),
	(N'S','2019-05-01 11:00:00',49,191,null,0),
	(N'S','2019-05-01 11:00:00',49,192,null,0),
	(N'S','2019-05-01 11:00:00',49,193,null,0),
	(N'S','2019-05-01 11:00:00',49,194,null,0),
	(N'S','2019-05-01 11:00:00',49,195,null,0),
	(N'S','2019-05-01 11:00:00',49,196,null,0),
	(N'S','2019-05-01 11:00:00',49,197,null,0),
	(N'S','2019-05-01 11:00:00',49,198,null,0),
	(N'S','2019-05-01 11:00:00',49,199,null,25),
	(N'S','2019-05-01 11:00:00',49,200,null,180)
GO