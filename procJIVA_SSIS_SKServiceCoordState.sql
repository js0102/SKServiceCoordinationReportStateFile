USE [JIVA]
GO
/****** Object:  StoredProcedure [dbo].[procJIVA_SSIS_SKServiceCoordState]    Script Date: 10/2/2023 4:12:09 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		Rafael Martinez
-- Create date: 20220502
-- Description:	This stored procedure exports data for the UMCM 5.24.10 Service Coordination report. This is for the LTSS version of the report.
--				This stored procedure will be used by SSIS and the resultant data will be formatted to a .txt file and uploaded to TexConnect.
--				The data is reported by month and this proc takes a start and end date as parameters. 
--				Since this is for LTSS, the only program reported is Star Kids. 
-- Modified:	20220513; Fixed issue with the risk group.
--				20220524; Fixing the issue with the risk group created dups in #effSK and threw off the counts of F2F and telephonic counts. This has been fixed.
--				Also, more INTERACTION_OUTCOMEs were added for UTR in #BuildForNoSPReason per request from Roxanne.
--				20220603; Fixing some issues that were causing file to fail
--				20220614; Fixed "[How many successful telephonic service coordination or service management visits?] > 0 and [If none why] != ''"
--						  Also fixed "Should be balnk from 566 when at least one service coordination contact attempt not made"
--						  Also fixed "is_memb_new_mshcn is required Field only for Star,StarHealth,Chip and MMP"
--				20220714; Fixed issue with duplicates in #effSK. Also, reviewed with Roxanne and adjusted logic for reasons for no sp reason, no f2f contacts, and no tele contacts
--				20230127; Added Star Kids Screening and Assessment 2.0 assessment to filters for [Has Service Plan] and [F2F Count] columns.

-- Jerry Simecek
--				20230412 - This is a production version which was also copied to CFISDEV17 to be sure we have the latest version over there
--				20230425 - Date parameters adjsuted to fit to the new package
--				20230929 - HD094021 - Updated Zeomeg Link Server
--				20231220 - HD096156 - Stored procedure renamed from procMSHCN_UMCM_5_24_10_LTSS to procJIVA_SSIS_SKServiceCoordState
-- =============================================
CREATE PROCEDURE [dbo].[procJIVA_SSIS_SKServiceCoordState](@reportMonthStart date, @reportMonthEnd date)


AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

--	DECLARE @reportMonthStart DATE, @reportMonthEnd DATE
--	SET @reportMonthStart = DATEFROMPARTS(YEAR(DATEADD(m, -1, GETDATE())), MONTH(DATEADD(m, -1, GETDATE())), 1);
--	SET @reportMonthEnd = DATEADD(d, -1, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1));




DECLARE @SFY INT = CASE WHEN @reportMonthStart >= CONCAT('9/1/', CAST(YEAR(@reportMonthStart) AS CHAR(4))) THEN YEAR(@reportMonthStart)+1 ELSE YEAR(@reportMonthStart) END

DECLARE @programid_sk VARCHAR(25) = 'QMXHPQD844' --sk; 04; KA
DECLARE @programid_ch VARCHAR(25) = 'QMXHPQD846' --ch; 05; 03
DECLARE @programid_s VARCHAR(25) = 'QMXHPQ0838' --s; 01; 42

BEGIN /* SELECT * FROM #effSK WHERE [Medicaid ID/PCN] = '754045157'; Starting point (SK Demographics); All effective SK*/ DECLARE @overwriteSKDemo INT = 1
	
	--Can use this to link to rest of JIVA. This is the starting point (all effective star kids)
	IF(@overwriteSKDemo = 1)
	BEGIN

	DROP TABLE IF EXISTS #effSK

	SELECT DISTINCT --TOP 1000
		/*Auxiliary*/
		ISNULL(VMMMIA.MBR_IDN, VMMMIE.MBR_IDN) EligID,
		p82_arch.CreateDate,
		ROW_NUMBER() OVER(PARTITION BY ek.carriermemid ORDER BY p82_arch.CreateDate DESC) AS OrderedRiskGroups,
		/***********/

		'' AS [Sequence]
		,'CFC' AS [MCO Name]
		,MONTH(@reportMonthStart) AS [Reporting Month]
		,@SFY AS [State Fiscal Year]
		,CASE
			WHEN ek.programid = @programid_sk THEN '04' --sk
			WHEN ek.programid = @programid_ch THEN '05' --ch
			WHEN ek.programid = @programid_s THEN '01' --s
		END AS [Program]
		,CASE
			WHEN ek.programid = @programid_sk THEN 'KA' --sk
			WHEN ek.programid = @programid_ch THEN '03' --ch
			WHEN ek.programid = @programid_s THEN '42' --s
		END AS [Plan Code] --42 star; KA star kids; 03 chip
		,ek.carriermemid AS [Medicaid ID/PCN]
		,m.dob AS [Member Date of Birth]
		,ent.firstname AS [First Name]
		,ent.lastname AS [Last Name]
		,ISNULL(ISNULL(RIGHT(p82.Risk_Group_ID,3),RIGHT(p82_arch.Risk_Group_ID,3)), ec.ratecode)  AS [Risk Group]
		,CASE
			WHEN ek.carriermemid NOT IN (
				SELECT i.carriermemid
				FROM	
					PlanData_rpt.dbo.enrollkeys i (NOLOCK) 	
				WHERE
					i.termdate >= DATEADD(DAY,-60, @reportMonthStart)
					AND i.effdate < @reportMonthStart
					AND ek.carriermemid = i.carriermemid
					AND i.programid IN (@programid_sk)
					AND i.segtype = 'INT'
				) THEN '01'
			ELSE '02'
		END AS [Is this Member new to the MCO in the reporting month?]

	INTO #effSK
	FROM
		PlanData_rpt.dbo.enrollkeys ek (NOLOCK)
	LEFT JOIN	
		PlanData_rpt.dbo.member m (NOLOCK) ON ek.memid = m.memid
	LEFT JOIN	
		PlanData_rpt.dbo.entity ent (NOLOCK) ON m.entityid = ent.entid 
	JOIN	
		PlanData_rpt.dbo.enrollcoverage ec (NOLOCK) ON ek.enrollid = ec.enrollid
	
	LEFT JOIN	
		QNXT.[Custom].[dbo].[cfhpt_CapImport_P82StarKids_Main_stg] p82 (nolock) on ek.carriermemid = p82.[Recipient_Medicaid_ID] 
			AND 
				CAST(CASE WHEN p82.End_Managed_Care = '00000000' THEN '12/31/2078' ELSE CAST(CONCAT(LEFT(p82.End_Managed_Care, 4), '/',SUBSTRING(p82.End_Managed_Care, 5, 2), '/', RIGHT(p82.End_Managed_Care,2)) AS DATE) END AS DATE)
				>= @reportMonthStart
			AND 
				CAST(CONCAT(LEFT(p82.Start_Managed_Care, 4), '/',SUBSTRING(p82.Start_Managed_Care, 5, 2), '/', RIGHT(p82.Start_Managed_Care,2)) AS DATE)
				< DATEADD(D,1,@reportMonthEnd)
	LEFT JOIN	
		QNXT.[Custom].[dbo].[cfhpt_CapImport_P82StarKids_Main_arch] p82_arch (nolock) on ek.carriermemid = p82_arch.[Recipient_Medicaid_ID] 
			AND 
				CAST(CASE WHEN p82_arch.End_Managed_Care = '00000000' THEN '12/31/2078' ELSE CAST(CONCAT(LEFT(p82_arch.End_Managed_Care, 4), '/',SUBSTRING(p82_arch.End_Managed_Care, 5, 2), '/', RIGHT(p82_arch.End_Managed_Care,2)) AS DATE) END AS DATE)
				>= @reportMonthStart
			AND 
				CAST(CONCAT(LEFT(p82_arch.Start_Managed_Care, 4), '/',SUBSTRING(p82_arch.Start_Managed_Care, 5, 2), '/', RIGHT(p82_arch.Start_Managed_Care,2)) AS DATE)
				< DATEADD(D,1,@reportMonthEnd)

	LEFT  JOIN 
		[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  ek.carriermemid = VMMMIA.MEMBER_ID COLLATE DATABASE_DEFAULT
																									and VMMMIA.ID_TYPE_CD = 'ALT'
																									and VMMMIA.active = 'Y'
	LEFT  JOIN 
		[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on ek.carriermemid = VMMMIE.MEMBER_ID COLLATE DATABASE_DEFAULT
																									and VMMMIE.ID_TYPE_CD = 'ELIG'
																									and VMMMIE.active = 'Y'
	WHERE
		ek.termdate >= @reportMonthStart AND ek.effdate < DATEADD(D,1,@reportMonthEnd)
		AND ek.programid = @programid_sk
		AND ek.segtype = 'INT'
		AND ec.termdate >= @reportMonthStart
		AND ec.effdate < DATEADD(D,1,@reportMonthEnd)

	DELETE FROM #effSK
	WHERE OrderedRiskGroups != 1

	END
END

BEGIN /* SELECT * FROM #LTSS WHERE [Medicaid ID/PCN] = '754045157'; Narrow down to LTSS Frequency ace*/ DECLARE @overwriteLTSS INT = 1

	IF (@overwriteLTSS = 1)
	BEGIN

	DROP TABLE IF EXISTS #LTSSFreq

	SELECT DISTINCT

		/*Auxiliary*/
		esk.EligID
		,VMEA.ACE_ENTITY_IDN
		,VMEA.ENC_IDN 
		,VMEA.ACE_DATE
		,VMEA.MBR_IDN
		/***********/

		,esk.[Sequence]
		,esk.[MCO Name]
		,esk.[Reporting Month]
		,esk.[State Fiscal Year]
		,esk.[Program]
		,esk.[Plan Code] --42 star; KA star kids; 03 chip
		,esk.[Medicaid ID/PCN]
		,CONVERT(DATE,esk.[Member Date of Birth],110) [Member Date of Birth]
		,esk.[First Name]
		,esk.[Last Name]
		,esk.[Risk Group] --ratecode off enrollcoverage
		,esk.[Is this Member new to the MCO in the reporting month?]

		,'' AS [Is this Member newly identified as MSHCN in the reporting month.]

		/*******************************/
		,CASE
			WHEN LEFT(VMEAR1.ANSWER, 1) = 'Y' THEN '01'
			WHEN LEFT(VMEAR1.ANSWER, 1) = 'N' THEN '02'
			ELSE '02'
		END AS [Did the Member decline service coordination or service management?] --"Most Current" Am I looking for this?
		--,CASE
		--	WHEN VMEAR2.ANSWER LIKE '%MDC%' THEN 'MDC'
		--	WHEN VMEAR2.ANSWER LIKE '%MLT%' THEN 'MLT'
		--	WHEN VMEAR2.ANSWER LIKE '%MAR%' THEN 'MAR'
		--	WHEN VMEAR2.ANSWER LIKE '%DEC%' THEN 'DEC'
		--	WHEN VMEAR2.ANSWER = 'Other:' THEN 'OTH'
		--	ELSE ''
		--END AS [If yes, why was service coordination or service management declined?]
		--,ISNULL(VMEAR2.LOV_VALUE, '') AS [If Other entered, enter a brief explanation]
		/*******************************/

		,CASE
			WHEN VMEA.ACE_ENTITY_IDN IS NULL THEN 1
			ELSE ROW_NUMBER() OVER(PARTITION BY VMEAR1.ACE_ENTITY_IDN, VMEAR1.QSTN_IDN ORDER BY VMEAR1.ACE_ENTITY_IDN, VMEAR1.QSTN_IDN, VMEAR1.UPDATED_DATE DESC)
		END AS QSTN1_ROW
		/*
		/*Green*/
		,'' AS [Does the Member have a service plan in place?]

		,'' AS [If the Member does not have a service plan in place, select the appropriate reason. ]
		,'' AS [If "Other" selected, provide a brief explanation. ]

		/*Pink*/
		,'' AS [Date the service plan was developed or last updated?]

		/*Orange*/
		,'' AS [What is the Members service coordination or service management level?]

		,'' AS [Was at least one service coordination or service management contact attempt made? ]

		/*******************************/
		,'' AS [How many successful face-to-face service coordination or service management visits?]
		/*******************************/

		,'' AS [If no successful face-to-face service coordination or service management visits, why not?]
		,'' AS [If Other, provide brief description. (F2F)]
		,'' AS [How many successful telephonic service coordination or service management visits?]
		,'' AS [If no successful telephonic service coordination or service management visits made, why not?]
		,'' AS [If Other, provide brief description. (TELEPHONIC)]
		*/


	INTO #LTSSFreq
	FROM
		#effSK esk
	LEFT JOIN
		[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA (NOLOCK) ON esk.EligID = VMEA.MBR_IDN 
																								AND VMEA.TITLE LIKE '%LTSS%FREQUENCY%'
																								AND VMEA.active = 'Y'
																								AND VMEA.ACE_STATUS = 'completed'
																								AND JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(VMEA.ACE_DATE) BETWEEN DATEADD(M,-12,@reportMonthStart) AND DATEADD(D,1,@reportMonthEnd)
	
	LEFT JOIN 
		[Zeomega].[dbo].[V_MODEL_EPISODE_ASSMT_RESULTS] VMEAR1 (NOLOCK) ON VMEAR1.ACE_ENTITY_IDN = VMEA.ACE_ENTITY_IDN  
																									and VMEAR1.QSTN_IDN IN ('5092047') --Does Member Decline all Service Coordination?
																									and VMEAR1.active = 'Y'
	/*
	LEFT JOIN 
		[Zeomega].[dbo].[V_MODEL_EPISODE_ASSMT_RESULTS] VMEAR2 (NOLOCK) ON VMEAR2.ACE_ENTITY_IDN = VMEA.ACE_ENTITY_IDN  
																									and VMEAR2.QSTN_IDN IN ('5092048') --If yes, why?
																									and VMEAR2.active = 'Y'
	*/

	
	ORDER BY
		1
	/**************************************/


	/*Grab latest *Does Member Decline all Service Coordination?*/
	DROP TABLE IF EXISTS #LTSSFreq_MostCurrent

	SELECT *, DATEADD(D,30,CAST(X.ACE_DATE AS DATE)) ACE_DATE_PLUS30, DATEADD(D,60,CAST(X.ACE_DATE AS DATE)) ACE_DATE_PLUS60
	INTO #LTSSFreq_MostCurrent
	FROM
	(
	SELECT *, ROW_NUMBER() OVER(PARTITION BY [Medicaid ID/PCN] ORDER BY [Medicaid ID/PCN], ACE_DATE DESC) MBR_LATEST

	FROM 
		#LTSSFreq LTSS
	WHERE
		QSTN1_ROW = 1 
	) X
	WHERE
		MBR_LATEST = 1


	/*Grab latest If yes, why?**/
	DROP TABLE IF EXISTS #LTSS_DECLINE_WHY

	SELECT 
		*
	INTO #LTSS_DECLINE_WHY
	FROM
	(
		SELECT LTSS.*
			,CASE
				WHEN VMEAR2.ANSWER LIKE '%MDC%' THEN 'MDC'
				WHEN VMEAR2.ANSWER LIKE '%MLT%' THEN 'MLT'
				WHEN VMEAR2.ANSWER LIKE '%MAR%' THEN 'MAR'
				WHEN VMEAR2.ANSWER LIKE '%DEC%' THEN 'DEC'
				WHEN VMEAR2.ANSWER = 'Other:' THEN 'OTH'
				ELSE '' --Come back to
			END AS [If yes, why was service coordination or service management declined?]
			,CASE
				WHEN LTSS.ACE_ENTITY_IDN IS NULL THEN 1
				ELSE ROW_NUMBER() OVER(PARTITION BY LTSS.ACE_ENTITY_IDN, VMEAR2.QSTN_IDN ORDER BY LTSS.ACE_ENTITY_IDN, VMEAR2.QSTN_IDN, VMEAR2.UPDATED_DATE DESC) 
			END DECLINE_LATEST
			,VMEAR2.ASSMT_RESULT_IDN
		FROM
			#LTSSFreq_MostCurrent LTSS
		LEFT JOIN 
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSMT_RESULTS] VMEAR2 (NOLOCK) ON VMEAR2.ACE_ENTITY_IDN = LTSS.ACE_ENTITY_IDN  
																									and VMEAR2.QSTN_IDN IN ('5092048') --If yes, why?
																									and VMEAR2.active = 'Y'
		--WHERE 
		--	(VMEAR2.ANSWER != 'Other:' OR (VMEAR2.ANSWER = 'Other:' AND VMEAR2.LOV_VALUE is NOT null) OR VMEAR2.ANSWER IS NULL) 
	) X
	WHERE
		X.DECLINE_LATEST = 1


	UPDATE #LTSS_DECLINE_WHY
	SET [If yes, why was service coordination or service management declined?] = 'OTH'
	WHERE
		[Did the Member decline service coordination or service management?] = '01'
		AND (
			[If yes, why was service coordination or service management declined?] = '' OR [If yes, why was service coordination or service management declined?] IS NULL
		)


	--GRAB LATEST * IF OTHER WHY
	DROP TABLE IF EXISTS #LTSS_IFOTHER

	SELECT
		*
	INTO #LTSS_IFOTHER
	FROM
	(
		SELECT LTSS.*
			,ISNULL(VMEAR2.LOV_VALUE, '') AS [If Other entered, enter a brief explanation]
			,CASE
				WHEN LTSS.ACE_ENTITY_IDN IS NULL THEN 1
				ELSE ROW_NUMBER() OVER(PARTITION BY LTSS.ACE_ENTITY_IDN, VMEAR2.QSTN_IDN ORDER BY LTSS.ACE_ENTITY_IDN, VMEAR2.QSTN_IDN, VMEAR2.ASSMT_RESULT_IDN DESC, VMEAR2.UPDATED_DATE DESC) 
			END IFOTHER_LATEST
		FROM 
			#LTSS_DECLINE_WHY LTSS
		LEFT JOIN 
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSMT_RESULTS] VMEAR2 (NOLOCK) ON LTSS.ACE_ENTITY_IDN = LTSS.ACE_ENTITY_IDN  
																									AND LTSS.ASSMT_RESULT_IDN = VMEAR2.ASSMT_RESULT_IDN
																									and VMEAR2.QSTN_IDN IN ('5092048') --If yes, why?
																									and VMEAR2.active = 'Y'
	) X
	WHERE
		X.IFOTHER_LATEST = 1


	UPDATE #LTSS_IFOTHER
	SET [If Other entered, enter a brief explanation] = 'OTH, REASON NOT STATED'
	WHERE
		[If yes, why was service coordination or service management declined?] = 'OTH'
		AND (
			[If Other entered, enter a brief explanation] = '' OR [If Other entered, enter a brief explanation] IS NULL
		)


	/*Reset #LTSSFreq table*/
	DROP TABLE IF EXISTS #LTSS
	
	SELECT DISTINCT 
		LTSS.* 
	INTO #LTSS
	FROM
		#effSK effSK
	LEFT JOIN
		#LTSS_IFOTHER LTSS ON effSK.[Medicaid ID/PCN] = LTSS.[Medicaid ID/PCN]
	ORDER BY
		ACE_ENTITY_IDN

	/*Drop unused tables*/
	DROP TABLE #LTSSFreq
	DROP TABLE #LTSSFreq_MostCurrent
	DROP TABLE #LTSS_DECLINE_WHY
	DROP TABLE #LTSS_IFOTHER

	--SELECT * FROM #LTSS
	--ORDER BY
	--	ACE_ENTITY_IDN DESC

	END
END

BEGIN /* SELECT * FROM #LevelOfSupport WHERE [Medicaid ID/PCN] = '754045157'; Regardless of Assessment, find Level Of Support*/ DECLARE @overwriteLOS INT = 1
	IF(@overwriteLOS = 1)
	BEGIN
		DROP TABLE IF EXISTS #LevelOfSupport

	SELECT DISTINCT
		/*Auxiliary*/
		esk.EligID,
		esk.ACE_ENTITY_IDN,
		VME.MBR_IDN,
		VME.ENC_IDN,
		/***********/

		esk.[Sequence]
		,esk.[MCO Name]
		,esk.[Reporting Month]
		,esk.[State Fiscal Year]
		,esk.[Program]
		,esk.[Plan Code] --42 star; KA star kids; 03 chip
		,esk.[Medicaid ID/PCN]
		,CONVERT(DATE,esk.[Member Date of Birth],110) [Member Date of Birth]
		,esk.[First Name]
		,esk.[Last Name]
		--,esk.[Risk Group] --ratecode off enrollcoverage
		,esk.[Is this Member new to the MCO in the reporting month?]
		--,'' AS [Is this Member newly identified as MSHCN in the reporting month.]

		--/*******************************/

		,esk.[Did the Member decline service coordination or service management?] 
		,esk.[If yes, why was service coordination or service management declined?]
		,esk.[If Other entered, enter a brief explanation]


		/*Green*/
		--,'' AS [Does the Member have a service plan in place?]
		/*First look at the assessment tab.  
		If the STAR Kids Screening and Assessment is "completed" on or within 90 days before or 60 days after the ISP start date, 
		and the ISP spans the report month, then 01.  
		If not, then 02.  The ISP should be in either completed or open status.*/

		/*Orange*/
		, VME.LEVEL_OF_SUPPORT AS [What is the Members service coordination or service management level?]
		/*However, if the indicated field is blank, THEN Enter 
		[Level 3=03 IF the Member Does Not Have Any of the following activities (below) in OPEN Status (anytime period), 
			LTSS - Initial Outreach Attempt 1;
			LTSS - Initial Outreach Attempt 2;
			LTSS - Initial Outreach Attempt 3;
		otherwise, Enter 06 (Member in Outreach Process) (i.e. if the member does have these activites in OPEN Status)*/

		, ROW_NUMBER() OVER(PARTITION BY VME.MBR_IDN ORDER BY VME.MBR_IDN, VME.UPDATED_DATE DESC) ENC_IDN_ROW

		INTO #LevelOfSupport
		FROM
			#LTSS esk
		JOIN
			[Zeomega].dbo.[V_MODEL_EPISODES] VME (NOLOCK) ON esk.EligID = VME.MBR_IDN
																						AND VME.EPISODE_TYPE LIKE '%Long Term Services and Supports%'

		--LEFT JOIN
		--	[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK) ON VME.ENC_IDN = TMPA.ENC_IDN

		ORDER BY
			1

		
		UPDATE #LevelOfSupport 
		SET [What is the Members service coordination or service management level?] = 'Level 6'
		WHERE 
			[What is the Members service coordination or service management level?] IS NULL
			AND ENC_IDN IN (SELECT TMPA.ENC_IDN FROM [Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
								WHERE 
									TMPA.ACTIVITY_STATUS = 'Open'
									AND (TMPA.ACTIVITY LIKE '%LTSS - Perform SAI Assessment%' OR TMPA.ACTIVITY LIKE '%LTSS - Initial Outreach Attempt%')
								)

		UPDATE #LevelOfSupport 
		SET [What is the Members service coordination or service management level?] = 'Level 3'
		WHERE 
			[What is the Members service coordination or service management level?] IS NULL


		DELETE FROM #LevelOfSupport
		WHERE
			ENC_IDN_ROW != 1

	
	--SELECT  * FROM #LevelOfSupport ORDER BY 1;
	END
END

BEGIN /* SELECT * FROM #SKScreen WHERE [Medicaid ID/PCN] = '754045157'; All completed star kids screening assessment */ DECLARE @overwriteSKS INT = 1
	IF(@overwriteSKS = 1)
	BEGIN
		/*This is used to find all completed SAI Assessments where the Ace_date is between DATEADD(D,-90,VMSPD_IN.ISP_START_DATE) AND DATEADD(D,60,VMSPD_IN.ISP_START_DATE)
		  where the ISP dates also span the report month*/
		DROP TABLE IF EXISTS ##ISPs

		SELECT VMEA_IN.ENC_IDN
			,VMEA_IN.TITLE
			,VMEA_IN.ACE_DATE
			,VMSPD_IN.ISP_START_DATE
			,VMSPD_IN.ISP_END_DATE
			,VMEA_IN.ACE_STATUS
			,VMD.DOCUMENT_TYPE
		INTO ##ISPs
		FROM [Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA_IN (NOLOCK)
			LEFT JOIN [Zeomega].[dbo].V_MODEL_SERVICE_PLAN_DETAILS VMSPD_IN (NOLOCK) ON VMEA_IN.ENC_IDN = VMSPD_IN.ENC_IDN
				AND VMSPD_IN.ISP_START_DATE <= CAST(CONVERT(VARCHAR(10),@reportMonthEnd, 101) AS DATE)
				AND VMSPD_IN.ISP_END_DATE >=  CAST(CONVERT(VARCHAR(10),@reportMonthStart, 101) AS DATE)
			LEFT JOIN [Zeomega].[dbo].V_MODEL_EPISODE_DOCUMENTS VMD (NOLOCK) ON VMEA_IN.ENC_IDN = VMD.ENC_IDN
				AND VMD.DOCUMENT_TYPE = 'LTSS Documentation Sent/Shared - ISP Upload'
				AND VMD.ADDED_DATE BETWEEN DATEADD(Year,-1,DATEADD(D,-90,VMSPD_IN.ISP_END_DATE)) AND DATEADD(D,-90,VMSPD_IN.ISP_END_DATE)
		WHERE VMEA_IN.MASTER_ACE_TITLE_IDN IN ('31923', '32166' ) 
			AND VMEA_IN.ACE_STATUS = 'Completed'
			AND CAST(VMEA_IN.ACE_DATE AS DATE) BETWEEN DATEADD(Year,-1,DATEADD(D,-90,VMSPD_IN.ISP_END_DATE)) AND DATEADD(D,-90,VMSPD_IN.ISP_END_DATE)
			AND VMD.DOCUMENT_TYPE IS NOT NULL 

		DROP TABLE IF EXISTS #SKScreen

		SELECT DISTINCT
			/*Auxiliary*/
			esk.EligID,
			VMEA.MBR_IDN,
			VMEA.ENC_IDN,

			/***********/

			esk.[Sequence]
			,esk.[MCO Name]
			,esk.[Reporting Month]
			,esk.[State Fiscal Year]
			,esk.[Program]
			,esk.[Plan Code] --42 star; KA star kids; 03 chip
			,esk.[Medicaid ID/PCN]
			,CONVERT(DATE,esk.[Member Date of Birth],110) [Member Date of Birth]
			,esk.[First Name]
			,esk.[Last Name]
			,esk.[Risk Group] --ratecode off enrollcoverage
			,esk.[Is this Member new to the MCO in the reporting month?]

			,'' AS [Is this Member newly identified as MSHCN in the reporting month.]

			/*******************************/

			/*Green*/
			,/*CASE
				WHEN EXISTS (
					SELECT VMSPD_IN.MBR_IDN
					FROM
						[Zeomega].[dbo].V_MODEL_SERVICE_PLAN_DETAILS VMSPD_IN (NOLOCK)
					WHERE
						CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(VMEA.ACE_DATE) AS DATE) BETWEEN DATEADD(D,-90,VMSPD_IN.ISP_START_DATE) AND DATEADD(D,60,VMSPD_IN.ISP_START_DATE) 
						AND VMSPD.ISP_START_DATE <= @reportMonthEnd
						AND VMSPD.ISP_END_DATE >= @reportMonthStart
						AND VMSPD_IN.ENC_IDN = VMEA.ENC_IDN
						AND esk.EligID = VMSPD_IN.MBR_IDN
					) THEN '01'
				ELSE '02'
			END*/'02' AS [Does the Member have a service plan in place?] --Mistake found and fixed 20220728
			/*Auxiliary*/
			,VMEA.ACE_ENTITY_IDN
			,JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(VMEA.ACE_DATE) ACE_DATE
			,VMSPD.ISP_START_DATE
			,VMSPD.ISP_END_DATE
			,VMEA.ENC_IDN AS ENC_IDN_SK
			/***********/
			/*First look at the assessment tab.  
			If the STAR Kids Screening and Assessment is "completed" on or within 90 days before or 60 days after the ISP start date, 
			and the ISP spans the report month, then 01.  
			If not, then 02.  The ISP should be in either completed or open status.*/

			,ROW_NUMBER() OVER(PARTITION BY esk.EligID ORDER BY esk.EligID, VMEA.ACE_DATE DESC, VMSPD.ISP_END_DATE DESC/*Meeting with Roxanne 20220726*/) LATESTENTITY

		INTO #SKScreen
		FROM
			#effSK esk
		LEFT JOIN
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA (NOLOCK) ON esk.EligID = VMEA.MBR_IDN
																								AND VMEA.MASTER_ACE_TITLE_IDN IN ('31923', '32166' ) --STAR Kids Screening and Assessment
																								AND VMEA.ACE_STATUS = 'Completed'
																								--AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(VMEA.ACE_DATE) AS DATE) <= @reportMonthEnd 
		LEFT JOIN	
			[Zeomega].[dbo].V_MODEL_SERVICE_PLAN_DETAILS VMSPD (NOLOCK) ON VMEA.ENC_IDN = VMSPD.ENC_IDN
																								---AND VMSPD.[STATUS] IN ('Open', 'Completed', 'Accepted') --Meeting with Roxanne 20220726
																								AND VMSPD.ISP_START_DATE <= @reportMonthEnd
																								AND VMSPD.ISP_END_DATE >= @reportMonthStart


		
		UPDATE SK
		SET [Does the Member have a service plan in place?] = '01'
		FROM #SKScreen SK
		WHERE
			SK.ENC_IDN_SK IN (SELECT ENC_IDN FROM ##ISPs)
		

		
		DELETE FROM #SKScreen
		WHERE LATESTENTITY != 1


		DROP TABLE ##ISPs

	END

END

BEGIN /* SELECT * FROM #f2FCounts --WHERE [Medicaid ID/PCN] = '754045157'; COUNTS OF F2F*/ DECLARE @overwriteF2F INT = 1
	IF (@overwriteF2F = 1)
	BEGIN
	DROP TABLE IF EXISTS #f2FCounts
	;WITH f2fCount AS 
	(SELECT 
		VMEA1.EligID [EligID]
		,COUNT(VMEA2.TITLE) [F2F COUNT]
	FROM 
		#effSK VMEA1
	LEFT join
		[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA2 (NOLOCK) ON VMEA1.EligID = VMEA2.MBR_IDN
																								AND VMEA2.TITLE = 'LTSS Face to Face Visit'
																								AND VMEA2.active = 'Y'
																								AND VMEA2.ACE_STATUS = 'completed'
	WHERE
		VMEA2.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

	GROUP BY
		VMEA1.EligID

	UNION ALL

	SELECT 
		VMEA1.EligID [EligID]
		,COUNT(VMEA3.TITLE) [F2F COUNT]
	FROM 
		#effSK VMEA1

	LEFT join
		[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA3 (NOLOCK) ON VMEA1.EligID = VMEA3.MBR_IDN
																								AND VMEA3.TITLE LIKE '%STAR KIDS SCRE%'
																								AND VMEA3.active = 'Y'
																								AND VMEA3.ACE_STATUS = 'completed'
	WHERE
		VMEA3.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

	GROUP BY
		VMEA1.EligID
	)

	SELECT
		EligID
		,SUM([F2F COUNT]) [F2F COUNT]
	INTO #f2FCounts
	FROM
		f2fCount 
	GROUP BY 
		EligId
	END
END

BEGIN /* SELECT * FROM #TeleVisitCounts WHERE [Medicaid ID/PCN] = '754045157'; TelephonicSC or SM visits*/ DECLARE @overwriteTele INT = 1
	IF (@overwriteTele = 1)
	BEGIN
		DROP TABLE IF EXISTS #TeleVisitCounts
		;WITH teleCount AS
		(SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA2.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1
		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA2 (NOLOCK) ON VMEA1.EligID = VMEA2.MBR_IDN
																									AND VMEA2.TITLE = 'LTSS Required Telephone Contact '
																									AND VMEA2.active = 'Y'
																									AND VMEA2.ACE_STATUS = 'completed'
		WHERE
			VMEA2.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA3.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1

		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA3 (NOLOCK) ON VMEA1.EligID = VMEA3.MBR_IDN
																									AND VMEA3.TITLE = 'LTSS ER Visit Follow up assessment'
																									AND VMEA3.active = 'Y'
																									AND VMEA3.ACE_STATUS = 'completed'
		WHERE
			VMEA3.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA4.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1

		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA4 (NOLOCK) ON VMEA1.EligID = VMEA4.MBR_IDN
																									AND VMEA4.TITLE = 'Texas STAR Kids Hospitalizations'
																									AND VMEA4.active = 'Y'
																									AND VMEA4.ACE_STATUS = 'completed'
		WHERE
			VMEA4.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA5.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1

		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA5 (NOLOCK) ON VMEA1.EligID = VMEA5.MBR_IDN
																									AND VMEA5.TITLE = 'BH Post Discharge Assessment'
																									AND VMEA5.active = 'Y'
																									AND VMEA5.ACE_STATUS = 'completed'
		WHERE
			VMEA5.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA2.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1
		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA2 (NOLOCK) ON VMEA1.EligID = VMEA2.MBR_IDN
																									AND VMEA2.TITLE = 'Transition Assessment Age 15-16'
																									AND VMEA2.active = 'Y'
																									AND VMEA2.ACE_STATUS = 'completed'
		WHERE
			VMEA2.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA2.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1
		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA2 (NOLOCK) ON VMEA1.EligID = VMEA2.MBR_IDN
																									AND VMEA2.TITLE = 'Transition Assessment Age 17'
																									AND VMEA2.active = 'Y'
																									AND VMEA2.ACE_STATUS = 'completed'
		WHERE
			VMEA2.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA2.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1
		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA2 (NOLOCK) ON VMEA1.EligID = VMEA2.MBR_IDN
																									AND VMEA2.TITLE = 'Transition Assessment Age 18-19'
																									AND VMEA2.active = 'Y'
																									AND VMEA2.ACE_STATUS = 'completed'
		WHERE
			VMEA2.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA2.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1
		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA2 (NOLOCK) ON VMEA1.EligID = VMEA2.MBR_IDN
																									AND VMEA2.TITLE = 'Transition Assessment Age 20'
																									AND VMEA2.active = 'Y'
																									AND VMEA2.ACE_STATUS = 'completed'
		WHERE
			VMEA2.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID

		UNION ALL

		SELECT 
			VMEA1.EligID [EligID]
			,COUNT(VMEA2.TITLE) [TELE COUNT]
		FROM 
			#effSK VMEA1
		LEFT join
			[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA2 (NOLOCK) ON VMEA1.EligID = VMEA2.MBR_IDN
																									AND VMEA2.TITLE = 'Telephonic Screening Assessment'
																									AND VMEA2.active = 'Y'
																									AND VMEA2.ACE_STATUS = 'completed'
		WHERE
			VMEA2.ACE_DATE BETWEEN @reportMonthStart AND DATEADD(D,1,@reportMonthEnd)

		GROUP BY
			VMEA1.EligID
		)

		SELECT
			EligID
			,SUM([TELE COUNT]) [TELE COUNT]
		INTO #TeleVisitCounts
		FROM
			teleCount 
		GROUP BY 
			EligId


	END
END

BEGIN /* SELECT * FROM #BuildForNoSPReason WHERE [Medicaid ID/PCN] = '754045157'; If no service plan why? */ DECLARE @OverwriteNoSPReason INT = 1
	IF (@OverwriteNoSPReason = 1)
	BEGIN 
	DROP TABLE IF EXISTS #BuildForNoSPReason
	SELECT DISTINCT
		LTSS.EligID
		,LTSS.MBR_IDN
		,LTSS.ENC_IDN
		/*Report start*/
		,LTSS.[Sequence]
		,LTSS.[MCO Name]
		,LTSS.[Reporting Month]
		,LTSS.[State Fiscal Year]
		,LTSS.[Program]
		,LTSS.[Plan Code] --42 star; KA star kids; 03 chip
		,LTSS.[Medicaid ID/PCN]
		,LTSS.[Member Date of Birth]
		,LTSS.[First Name]
		,LTSS.[Last Name]
		,LTSS.[Risk Group] --ratecode off enrollcoverage
		,LTSS.[Is this Member new to the MCO in the reporting month?] --Empty. Need to figure this out

		,LTSS.[Is this Member newly identified as MSHCN in the reporting month.]

		,LTSS.[Did the Member decline service coordination or service management?] --"Most Current" Am I looking for this?
		,LTSS.[If yes, why was service coordination or service management declined?]
		,LTSS.[If Other entered, enter a brief explanation]

		,ISNULL(SKS.[Does the Member have a service plan in place?],'02') AS [Does the Member have a service plan in place?]

		,CAST('' AS VARCHAR(3)) AS [If the Member does not have a service plan in place, select the appropriate reason. ]
		,CAST('' AS VARCHAR(255)) AS [If "Other" selected, provide a brief explanation. ]
		--,'' AS [Date the service plan was developed or last updated?]

		,ISNULL(CAST('0' AS CHAR(1)) + RIGHT(LOS.[What is the Members service coordination or service management level?],1),'06')  AS [What is the Members service coordination or service management level?]
		--,'' AS [Was at least one service coordination or service management contact attempt made? ]

		/*******************************/
		,ISNULL(F.[F2F COUNT], 0) [How many successful face-to-face service coordination or service management visits?]
		/*******************************/

		--,CAST('' AS VARCHAR(3)) AS [If no successful face-to-face service coordination or service management visits, why not?]
		--,CAST('' AS VARCHAR(150)) AS [If Other, provide brief description. (F2F)]

		,TELE.[TELE COUNT] AS [How many successful telephonic service coordination or service management visits?]

		--,'' AS [If no successful telephonic service coordination or service management visits made, why not?]
		--,'' AS [If Other, provide brief description. (TELEPHONIC)]
		INTO #BuildForNoSPReason
	FROM
		#LTSS LTSS
	LEFT JOIN
		#f2FCounts F ON LTSS.EligID = F.EligID
	LEFT JOIN
		#SKScreen SKS ON LTSS.EligID = SKS.EligID 
	LEFT JOIN
		#LevelOfSupport LOS ON LTSS.EligID = LOS.EligID
	LEFT JOIN
		#TeleVisitCounts TELE ON LTSS.EligID = TELE.EligID
	--WHErE
	--	[Medicaid ID/PCN] IN ('520697704') 
	ORDER BY
		1,2,3,10

		--SELECT TOP 1000 * FROM #BuildForNoSPReason WHERE EligID IS NULL


	--INP RANK 5
	UPDATE #BuildForNoSPReason
	SET [If the Member does not have a service plan in place, select the appropriate reason. ] = 'INP'
	WHERE EligID IN (
		SELECT 
			TMPA.MBR_IDN
		FROM
			[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
		LEFT  JOIN 
			[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																										and VMMMIA.ID_TYPE_CD = 'ALT'
																										and VMMMIA.active = 'Y'
		LEFT  JOIN 
			[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																										and VMMMIE.ID_TYPE_CD = 'ELIG'
																										and VMMMIE.active = 'Y'
		WHERE
			TMPA.ACTIVITY IN (
				'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment',
				'LTSS - Unreachable 6 Month Call',
				'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment',
				'LTSS - Annual SAI Outreach Attempt 3',
				'LTSS - Annual SAI Outreach Attempt 2',
				'LTSS - Initial Outreach Attempt 1',
				'LTSS - Initial Outreach Attempt 2',
				'LTSS - Initial Outreach Attempt 3',
				'LTSS - Priority Outreach Contact - Schedule Initial SAI',
				'LTSS - Perform SAI Assessment Telehealth',
				'LTSS - Perform SAI Assessment In Person',
				'LTSS - Perform SAI Assessment',
				'LTSS - Perform SAI Assessment Telephone'
			)
			AND TMPA.ACTIVITY_STATUS = 'Open'
			AND TMPA.ACTIVE = 'Y'
		)
		AND [Does the Member have a service plan in place?] = '02'


	--UTR RANK 4
	UPDATE #BuildForNoSPReason 
	SET [If the Member does not have a service plan in place, select the appropriate reason. ] = 'UTR'
	WHERE EligID IN (
		SELECT
			TMPA.MBR_IDN
		FROM
			[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
		JOIN
			[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
		LEFT  JOIN 
			[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																										and VMMMIA.ID_TYPE_CD = 'ALT'
																										and VMMMIA.active = 'Y'
		LEFT  JOIN 
			[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																										and VMMMIE.ID_TYPE_CD = 'ELIG'
																										and VMMMIE.active = 'Y'
		WHERE	
			TMPA.ACTIVITY IN (
				'LTSS - Initial Outreach Attempt 3'
				, 'LTSS - Annual SAI Outreach Attempt 3'
				, 'LTSS - Unreachable 6 Month Call'
				, 'LTSS - Priority Outreach Contact - Schedule Initial SAI'
				, 'LTSS - Initial Outreach Attempt 1'
				, 'LTSS - Initial Outreach Attempt 2'
				, 'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment'
				, 'LTSS - Annual SAI Outreach Attempt 2'
				, 'LTSS - Perform SAI Assessment'
				, 'LTSS - Perform SAI Assessment In Person'
				, 'LTSS - Perform SAI Assessment Telehealth'
				, 'LTSS - Perform SAI Assessment Telephone'
				)
			AND TMPA.ACTIVITY_STATUS = 'Closed'
			--AND VMIA.INTERACTION_OUTCOME IN (
			--	'LTSS Unreachable',
			--	'LTSS No Answer',
			--	'LTSS Left Voice Message',
			--	'LTSS Unsuccessful - Callback in 1 Month',
			--	'LTSS Unsuccessful - Callback in 2 Months',
			--	'LTSS Unsuccessful - Callback in 3 Months')
			AND VMIA.INTERACTION_STATUS = 'Unsuccessful'
			AND TMPA.ACTIVE = 'Y'
			AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN DATEADD(M,-12,@reportMonthStart) AND @reportMonthEnd 
		)
		AND [Does the Member have a service plan in place?] = '02'


	--MLT RANK 3
	UPDATE #BuildForNoSPReason
	SET [If the Member does not have a service plan in place, select the appropriate reason. ] = 'MLT'
	WHERE
		[Did the Member decline service coordination or service management?] = '01' AND [If yes, why was service coordination or service management declined?] = 'MLT'
		AND [Does the Member have a service plan in place?] = '02'

	--DEC RANK 2
	UPDATE #BuildForNoSPReason
	SET [If the Member does not have a service plan in place, select the appropriate reason. ] = 'DEC'
	WHERE
		[Did the Member decline service coordination or service management?] = '01'
		AND [Does the Member have a service plan in place?] = '02'

	--MDC; RANK LAST
	UPDATE #BuildForNoSPReason
	SET [If the Member does not have a service plan in place, select the appropriate reason. ] = 'MDC'
	WHERE
		EligID IN (
			SELECT
				VMEA.MBR_IDN
			FROM
				[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA (NOLOCK) 
			JOIN
				[Zeomega].[dbo].[V_MODEL_MEMBERS] VMM (NOLOCK) ON VMEA.MBR_IDN = VMM.MBR_IDN
			LEFT  JOIN 
				[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  VMEA.MBR_IDN = VMMMIA.MBR_IDN 
																											and VMMMIA.ID_TYPE_CD = 'ALT'
																											and VMMMIA.active = 'Y'
			LEFT  JOIN 
				[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on VMEA.MBR_IDN = VMMMIE.MBR_IDN
																											and VMMMIE.ID_TYPE_CD = 'ELIG'
																											and VMMMIE.active = 'Y'
			WHERE
				VMEA.TITLE = 'Deceased Member Checklist'
				AND VMEA.ACE_STATUS = 'Completed'
				AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(VMM.DATE_OF_DEATH) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
		)

	--OTH
	UPDATE #BuildForNoSPReason
	SET [If the Member does not have a service plan in place, select the appropriate reason. ] = 'OTH'
	WHERE
		[If the Member does not have a service plan in place, select the appropriate reason. ] NOT IN ('INP', 'UTR', 'MLT', 'DEC', 'MDC')
		AND [Does the Member have a service plan in place?] = '02'

	--IF OTHER WHY?
	UPDATE #BuildForNoSPReason
	SET [If "Other" selected, provide a brief explanation. ] = 
							'Unable to determine based on documentation crosswalk'
	WHERE
		[If the Member does not have a service plan in place, select the appropriate reason. ] = 'OTH'


	END
END

BEGIN /* SELECT * FROM #BuildForNoFTFReason WHERE [Medicaid ID/PCN] = '754045157'; If no successful FTF why? */ DECLARE @OverwriteNoFTFReason INT = 1
	IF(@OverwriteNoFTFReason = 1)
	BEGIN
		DROP TABLE IF EXISTS #BuildForNoFTFReason
		
		SELECT 
			LTSS.EligID
			,LTSS.MBR_IDN
			,LTSS.ENC_IDN
			/*Report start*/
			,LTSS.[Sequence]
			,LTSS.[MCO Name]
			,LTSS.[Reporting Month]
			,LTSS.[State Fiscal Year]
			,LTSS.[Program]
			,LTSS.[Plan Code] --42 star; KA star kids; 03 chip
			,LTSS.[Medicaid ID/PCN]
			,LTSS.[Member Date of Birth]
			,LTSS.[First Name]
			,LTSS.[Last Name]
			,LTSS.[Risk Group] --ratecode off enrollcoverage
			,LTSS.[Is this Member new to the MCO in the reporting month?] --Empty. Need to figure this out

			,LTSS.[Is this Member newly identified as MSHCN in the reporting month.]

			,LTSS.[Did the Member decline service coordination or service management?] --"Most Current" Am I looking for this?
			,LTSS.[If yes, why was service coordination or service management declined?]
			,LTSS.[If Other entered, enter a brief explanation]

			,LTSS.[Does the Member have a service plan in place?]

			,LTSS.[If the Member does not have a service plan in place, select the appropriate reason. ]
			,LTSS.[If "Other" selected, provide a brief explanation. ]
			--,'' AS [Date the service plan was developed or last updated?]

			,LTSS.[What is the Members service coordination or service management level?]
			--,'' AS [Was at least one service coordination or service management contact attempt made? ]

			/*******************************/
			,LTSS.[How many successful face-to-face service coordination or service management visits?]
			/*******************************/

			,CAST('' AS VARCHAR(3)) AS [If no successful face-to-face service coordination or service management visits, why not?]
			,CAST('' AS VARCHAR(150)) AS [If Other, provide brief description. (F2F)]

			,LTSS.[How many successful telephonic service coordination or service management visits?]

			--,'' AS [If no successful telephonic service coordination or service management visits made, why not?]
			--,'' AS [If Other, provide brief description. (TELEPHONIC)]
		INTO #BuildForNoFTFReason
		FROM
			#BuildForNoSPReason LTSS


		--OTH; RANK FIRST
		UPDATE #BuildForNoFTFReason
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'OTH'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Schedule F2F for LOS 1 Member'
						,'LTSS - Priority Outreach Contact - Schedule F2F for LOS 2 Member'
						,'LTSS - Perform Face to Face'
						,'LTSS - Perform Face to Face In Person'
						,'LTSS - Perform Face to Face Telehealth'
						,'LTSS - Perform Face to Face Telephone'
						,'LTSS - Perform SAI Assessment'
						,'LTSS - Perform SAI Assessment In Person'
						,'LTSS - Perform SAI Assessment Telehealth'
						,'LTSS - Perform SAI Assessment Telephone'
						,'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment'
						,'LTSS - Annual SAI Outreach Attempt 2'
						,'LTSS - Annual SAI Outreach Attempt 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						/*Meeting with Roxanne 20220726 1753*/
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 1'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 2'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 3'
						,'LTSS - MDCP/PDN/PPECC Perform Transition Visit FTF'
						,'LTSS - Perform Transition Visit In Person'
						,'LTSS - Perform Transition Visit Telehealth'
					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND TMPA.ACTIVE = 'Y'
			)
			AND [How many successful face-to-face service coordination or service management visits?] = 0

		--F2F; RANK 6
		UPDATE #BuildForNoFTFReason
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'F2F'
		WHERE
			EligID NOT IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE --DO NOT HAVE ANY OF THE FOLLOWING IN CLOSED OR OPEN.
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Schedule F2F for LOS 1 Member'
						,'LTSS - Priority Outreach Contact - Schedule F2F for LOS 2 Member'
						,'LTSS - Perform Face to Face'
						,'LTSS - Perform Face to Face In Person'
						,'LTSS - Perform Face to Face Telehealth'
						,'LTSS - Perform Face to Face Telephone'
						,'LTSS - Perform SAI Assessment In Person'
						,'LTSS - Perform SAI Assessment Telehealth'
						,'LTSS - Perform SAI Assessment Telephone'
						,'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment'
						,'LTSS - Annual SAI Outreach Attempt 2'
						,'LTSS - Annual SAI Outreach Attempt 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						/*Meeting with Roxanne 20220726 1753*/
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 1'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 2'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 3'
						,'LTSS - MDCP/PDN/PPECC Perform Transition Visit FTF'
						,'LTSS - Perform Transition Visit In Person'
						,'LTSS - Perform Transition Visit Telehealth'
					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND TMPA.ACTIVE = 'Y'
			)
			AND [How many successful face-to-face service coordination or service management visits?] = 0

		--UTR; RANK 5
		--UPDATE #BuildForNoFTFReason
		--SET [If no successful face-to-face service coordination or service management visits, why not?] = 'UTR'
		--WHERE
		--	ENC_IDN IN (
		--		SELECT 
		--			TMPA.ENC_IDN
		--		FROM
		--			[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
		--		JOIN
		--			[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
		--		WHERE
		--			TMPA.ACTIVITY IN (
		--				'LTSS - Priority Outreach Contact - Schedule F2F for LOS 1 Member'
		--				,'LTSS - Priority Outreach Contact - Schedule F2F for LOS 2 Member'
		--				,'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment'
		--				,'LTSS - Annual SAI Outreach Attempt 2'
		--				,'LTSS - Annual SAI Outreach Attempt 3'
		--				,'LTSS - Initial Outreach Attempt 1'
		--				,'LTSS - Initial Outreach Attempt 2'
		--				,'LTSS - Initial Outreach Attempt 3'
		--			)
		--			AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN DATEADD(D,-90,@reportMonthStart) AND @reportMonthEnd
		--			AND TMPA.ACTIVITY_STATUS = 'Closed'
		--			AND VMIA.INTERACTION_STATUS = 'Unsuccessful'
		--			AND TMPA.ACTIVE = 'Y'
		--			AND VMIA.INTERACTION_OUTCOME IN (
		--				'LTSS Left Voice Message'
		--				,'LTSS No Answer'
		--				,'LTSS Unreachable'
		--				,'LTSS Unsuccessful - Callback in 1 Month'
		--				,'LTSS Unsuccessful - Callback in 2 Months'
		--				,'LTSS Unsuccessful - Callback in 3 Months'
		--				,'LTSS Unsuccessful - Schedule F2F in 6 Months'
		--				,'LTSS Unsuccessful - Schedule F2F in 3 Months'
		--			)
		--	)
		--	AND [How many successful face-to-face service coordination or service management visits?] = 0
				
		UPDATE #BuildForNoFTFReason
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'UTR'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
					'LTSS - Perform Face to Face In Person'
					,'LTSS - Perform Face to Face'
					,'LTSS - Perform Face to Face Telehealth'
					,'LTSS - Perform Face to Face Telephone'
					,'LTSS - Perform SAI Assessment'
					,'LTSS - Perform SAI Assessment In Person'
					,'LTSS - Perform SAI Assessment Telehealth'
					,'LTSS - Perform SAI Assessment Telephone'
					,'LTSS - Priority Outreach Contact - Schedule F2F for LOS 1 Member'
					,'LTSS - Priority Outreach Contact - Schedule F2F for LOS 2 Member'
					,'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment'
					,'LTSS - Annual SAI Outreach Attempt 2'
					,'LTSS - Annual SAI Outreach Attempt 3'
					,'LTSS - Initial Outreach Attempt 1'
					,'LTSS - Initial Outreach Attempt 2'
					,'LTSS - Initial Outreach Attempt 3'
					/*Meeting with Roxanne 20220726 1753*/
					,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 1'
					,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 2'
					,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 3'
					,'LTSS - MDCP/PDN/PPECC Perform Transition Visit FTF'
					,'LTSS - Perform Transition Visit In Person'
					,'LTSS - Perform Transition Visit Telehealth'
					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND VMIA.INTERACTION_STATUS = 'Unsuccessful'
					AND TMPA.ACTIVE = 'Y'
					--AND VMIA.INTERACTION_OUTCOME NOT IN (
					--	'LTSS Member/LAR no show'
					--)
			)
			AND [How many successful face-to-face service coordination or service management visits?] = 0


		--MAR; RANK 4
		UPDATE #BuildForNoFTFReason
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'MAR'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Perform Face to Face'
						,'LTSS - Perform Face to Face In Person'
						,'LTSS - Perform Face to Face Telehealth'
						,'LTSS - Perform Face to Face Telephone'
						,'LTSS - Perform SAI Assessment'
						,'LTSS - Perform SAI Assessment In Person'
						,'LTSS - Perform SAI Assessment Telehealth'
						,'LTSS - Perform SAI Assessment Telephone'
						/*Meeting with Roxanne 20220726 1753*/
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 1'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 2'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 3'
						,'LTSS - MDCP/PDN/PPECC Perform Transition Visit FTF'
						,'LTSS - Perform Transition Visit In Person'
						,'LTSS - Perform Transition Visit Telehealth'
					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND VMIA.INTERACTION_STATUS = 'Unsuccessful'
					AND TMPA.ACTIVE = 'Y'
					AND VMIA.INTERACTION_OUTCOME IN (
						'LTSS Member/LAR at Risk'
					)
			)
			AND [How many successful face-to-face service coordination or service management visits?] = 0


		--MLT; RANK 3
		UPDATE #BuildForNoFTFReason
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'MLT'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Schedule F2F for LOS 1 Member'
						,'LTSS - Priority Outreach Contact - Schedule F2F for LOS 2 Member'
						,'LTSS - Perform Face to Face In Person'
						,'LTSS - Perform Face to Face'
						,'LTSS - Perform Face to Face Telehealth'
						,'LTSS - Perform Face to Face Telephone'
						,'LTSS - Perform SAI Assessment'
						,'LTSS - Perform SAI Assessment In Person'
						,'LTSS - Perform SAI Assessment Telehealth'
						,'LTSS - Perform SAI Assessment Telephone'
						,'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment'
						,'LTSS - Annual SAI Outreach Attempt 2'
						,'LTSS - Annual SAI Outreach Attempt 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						/*Meeting with Roxanne 20220726 1753*/
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 1'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 2'
						,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 3'
						,'LTSS - MDCP/PDN/PPECC Perform Transition Visit FTF'
						,'LTSS - Perform Transition Visit In Person'
						,'LTSS - Perform Transition Visit Telehealth'
					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND VMIA.INTERACTION_STATUS = 'Successful'
					AND TMPA.ACTIVE = 'Y'
					AND VMIA.INTERACTION_OUTCOME IN (
						'LTSS Member/LAR left the state or Service Area'
					)
			)
			AND [How many successful face-to-face service coordination or service management visits?] = 0


		--DEC; RANK 2
		UPDATE #BuildForNoFTFReason
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'DEC'
		WHERE
			[If yes, why was service coordination or service management declined?] = 'DEC'
			OR (
				EligID IN (
					SELECT 
						TMPA.MBR_IDN
					FROM
						[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
					JOIN
						[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
					LEFT  JOIN 
						[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																													and VMMMIA.ID_TYPE_CD = 'ALT'
																													and VMMMIA.active = 'Y'
					LEFT  JOIN 
						[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																													and VMMMIE.ID_TYPE_CD = 'ELIG'
																													and VMMMIE.active = 'Y'
					WHERE
						TMPA.ACTIVITY IN (
							'LTSS - Priority Outreach Contact - Schedule F2F for LOS 1 Member'
							,'LTSS - Priority Outreach Contact - Schedule F2F for LOS 2 Member'
							,'LTSS - Perform Face to Face In Person'
							,'LTSS - Perform Face to Face'
							,'LTSS - Perform Face to Face Telehealth'
							,'LTSS - Perform Face to Face Telephone'
							/*Meeting with Roxanne 20220726 1753*/
							,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 1'
							,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 2'
							,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 3'
							,'LTSS - MDCP/PDN/PPECC Perform Transition Visit FTF'
							,'LTSS - Perform Transition Visit In Person'
							,'LTSS - Perform Transition Visit Telehealth'
						)
						AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd --Meeting with Roxanne 20220727
						AND TMPA.ACTIVITY_STATUS = 'Closed'
						AND VMIA.INTERACTION_STATUS = 'Successful'
						AND TMPA.ACTIVE = 'Y'
						AND VMIA.INTERACTION_OUTCOME = 'LTSS Member/LAR Declined F2F'
				)
			)
			OR (
				EligID IN (
					SELECT 
						TMPA.MBR_IDN
					FROM
						[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
					JOIN
						[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
					LEFT  JOIN 
						[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																													and VMMMIA.ID_TYPE_CD = 'ALT'
																													and VMMMIA.active = 'Y'
					LEFT  JOIN 
						[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																													and VMMMIE.ID_TYPE_CD = 'ELIG'
																													and VMMMIE.active = 'Y'
					WHERE
						TMPA.ACTIVITY IN (
							 'LTSS - Perform SAI Assessment In Person'
							,'LTSS - Perform SAI Assessment'
							,'LTSS - Perform SAI Assessment Telehealth'
							,'LTSS - Perform SAI Assessment Telephone'
							,'LTSS - Priority Outreach Contact - Schedule Annual SAI Reassessment'
							,'LTSS - Annual SAI Outreach Attempt 2'
							,'LTSS - Annual SAI Outreach Attempt 3'
							,'LTSS - Initial Outreach Attempt 1'
							,'LTSS - Initial Outreach Attempt 2'
							,'LTSS - Initial Outreach Attempt 3'
							/*Meeting with Roxanne 20220726 1753*/
							,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 1'
							,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 2'
							,'LTSS - MDCP/PDN/PPECC POC - FTF Transition Attempt 3'
							,'LTSS - MDCP/PDN/PPECC Perform Transition Visit FTF'
							,'LTSS - Perform Transition Visit In Person'
							,'LTSS - Perform Transition Visit Telehealth'
						)
						AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd--Meeting with Roxanne 20220727
						AND TMPA.ACTIVITY_STATUS = 'Closed'
						AND VMIA.INTERACTION_STATUS = 'Successful'
						AND VMIA.INTERACTION_OUTCOME = 'LTSS Member/LAR declined SAI'
				)
			)
			AND [How many successful face-to-face service coordination or service management visits?] = 0


		--MDC; RANK LAST
		UPDATE #BuildForNoFTFReason 
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'MDC'
		WHERE
			ENC_IDN IN (
				SELECT
					VMEA.ENC_IDN
				FROM
					[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA (NOLOCK) 
				JOIN
					[Zeomega].[dbo].[V_MODEL_MEMBERS] VMM (NOLOCK) ON VMEA.MBR_IDN = VMM.MBR_IDN AND VMM.ACTIVE = 'Y'

				WHERE
					VMEA.TITLE = 'Deceased Member Checklist'
					AND VMEA.ACE_STATUS = 'Completed'
					AND VMEA.ACTIVE = 'Y'
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(VMM.DATE_OF_DEATH) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
			)
			AND [How many successful face-to-face service coordination or service management visits?] = 0

		--If all else fails, OTH
		UPDATE #BuildForNoFTFReason
		SET [If no successful face-to-face service coordination or service management visits, why not?] = 'OTH'
		WHERE
			[How many successful face-to-face service coordination or service management visits?] = 0
			AND ([If no successful face-to-face service coordination or service management visits, why not?] = '' OR [If no successful face-to-face service coordination or service management visits, why not?] IS NULL)

		
		--IF OTHER WHY?
		UPDATE #BuildForNoFTFReason
		SET [If Other, provide brief description. (F2F)] = 'Not F2F but activity outcome selected by the SC does not allow for categorization into the DEC, UTR, or MLT category'
		WHERE
			[If no successful face-to-face service coordination or service management visits, why not?] = 'OTH'




		--SELECT * FROM #BuildForNoFTFReason
	END
END

BEGIN /* SELECT * FROM #BuildForNoTeleVisit WHERE [Medicaid ID/PCN] = '754045157'; */ DECLARE @OverwriteNoTele INT = 1

	IF (@OverwriteNoTele = 1)
	BEGIN
	
		DROP TABLE IF EXISTS #BuildForNoTeleVisit

		SELECT 
			LTSS.EligID
			,LTSS.MBR_IDN
			,LTSS.ENC_IDN
			/*Report start*/
			,LTSS.[Sequence]
			,LTSS.[MCO Name]
			,LTSS.[Reporting Month]
			,LTSS.[State Fiscal Year]
			,LTSS.[Program]
			,LTSS.[Plan Code] --42 star; KA star kids; 03 chip
			,LTSS.[Medicaid ID/PCN]
			,LTSS.[Member Date of Birth]
			,LTSS.[First Name]
			,LTSS.[Last Name]
			,LTSS.[Risk Group] --ratecode off enrollcoverage
			,LTSS.[Is this Member new to the MCO in the reporting month?] --Empty. Need to figure this out

			,LTSS.[Is this Member newly identified as MSHCN in the reporting month.]

			,LTSS.[Did the Member decline service coordination or service management?] --"Most Current" Am I looking for this?
			,LTSS.[If yes, why was service coordination or service management declined?]
			,LTSS.[If Other entered, enter a brief explanation]

			,LTSS.[Does the Member have a service plan in place?]

			,LTSS.[If the Member does not have a service plan in place, select the appropriate reason. ]
			,LTSS.[If "Other" selected, provide a brief explanation. ]
			--,'' AS [Date the service plan was developed or last updated?]

			,LTSS.[What is the Members service coordination or service management level?]
			--,'' AS [Was at least one service coordination or service management contact attempt made? ]

			/*******************************/
			,LTSS.[How many successful face-to-face service coordination or service management visits?] 
			/*******************************/

			--,CAST('' AS VARCHAR(3)) AS [If no successful face-to-face service coordination or service management visits, why not?]
			--,CAST('' AS VARCHAR(150)) AS [If Other, provide brief description. (F2F)]

			,ISNULL(LTSS.[How many successful telephonic service coordination or service management visits?], 0) [How many successful telephonic service coordination or service management visits?]

			,CAST('' AS VARCHAR(3)) AS [If no successful telephonic service coordination or service management visits made, why not?]
			,CAST('' AS VARCHAR(150)) AS [If Other, provide brief description. (TELEPHONIC)]
		
		INTO #BuildForNoTeleVisit
		FROM
			#BuildForNoSPReason LTSS
		


		--TEL; RANK 5
		UPDATE #BuildForNoTeleVisit
		SET [If no successful telephonic service coordination or service management visits made, why not?] = 'TEL'
		WHERE
			EligID NOT IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 1'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 2'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						,'LTSS - IP Discharge Follow Up'
						,'LTSS - IP Discharge Follow Up outreach attempt 2'
						,'LTSS - IP Discharge Follow Up outreach attempt 3'
						,'LTSS - ER visit follow up Assessment'
						,'LTSS - ER follow up outreach attempt 2'
						,'LTSS - ER follow up outreach attempt 3'
						,'BH 7 Day Follow Up Call Back 1'
						,'BH 7 Day Follow Up Call Back 2'
						,'BH 7 Day Follow Up Call Back 3',
						/*Added 20220726 1734*/
						'LTSS - POC Transition Attempt 1',
						'LTSS - POC Transition Attempt 2',
						'LTSS - POC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 1',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 2',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 1',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 2',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 3'
						,'LTSS - Perform Transition Visit Telephone'
						,'LTSS - Priority Outreach Contact - 4 Week Follow Up'

					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND TMPA.ACTIVE = 'Y'
			)
			AND [How many successful telephonic service coordination or service management visits?] = 0

		
		--UTR; RANK 4
		UPDATE #BuildForNoTeleVisit
		SET [If no successful telephonic service coordination or service management visits made, why not?] = 'UTR'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 1'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 2'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						,'LTSS - IP Discharge Follow Up'
						,'LTSS - IP Discharge Follow Up outreach attempt 2'
						,'LTSS - IP Discharge Follow Up outreach attempt 3'
						,'LTSS - ER visit follow up Assessment'
						,'LTSS - ER follow up outreach attempt 2'
						,'LTSS - ER follow up outreach attempt 3'
						,'BH 7 Day Follow Up Call Back 1'
						,'BH 7 Day Follow Up Call Back 2'
						,'BH 7 Day Follow Up Call Back 3',
						/*Added 20220726 1734*/
						'LTSS - POC Transition Attempt 1',
						'LTSS - POC Transition Attempt 2',
						'LTSS - POC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 1',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 2',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 1',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 2',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 3'
						,'LTSS - Perform Transition Visit Telephone'
						,'LTSS - Priority Outreach Contact - 4 Week Follow Up'

					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND TMPA.ACTIVE = 'Y'
					--AND VMIA.INTERACTION_OUTCOME IN (
					--	'LTSS Left Voice Message'
					--	,'LTSS No Answer'
					--	,'LTSS Unreachable'
					--	,'LTSS Unsuccessful - Callback in 1 Month'
					--	,'LTSS Unsuccessful - Callback in 2 Months'
					--	,'LTSS Unsuccessful - Callback in 3 Months'
					--)
					AND VMIA.INTERACTION_STATUS = 'Unsuccessful'
			)
			AND [How many successful telephonic service coordination or service management visits?] = 0


		--MLT; RANK 3
		UPDATE #BuildForNoTeleVisit
		SET [If no successful telephonic service coordination or service management visits made, why not?] = 'MLT'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 1'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 2'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						
						,'LTSS - IP Discharge Follow Up'
						,'LTSS - IP Discharge Follow Up outreach attempt 2'
						,'LTSS - IP Discharge Follow Up outreach attempt 3'
						,'LTSS - ER visit follow up Assessment'
						,'LTSS - ER follow up outreach attempt 2'
						,'LTSS - ER follow up outreach attempt 3'
						,'BH 7 Day Follow Up Call Back 1'
						,'BH 7 Day Follow Up Call Back 2'
						,'BH 7 Day Follow Up Call Back 3',
						/*Added 20220726 1734*/
						'LTSS - POC Transition Attempt 1',
						'LTSS - POC Transition Attempt 2',
						'LTSS - POC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 1',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 2',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 1',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 2',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 3'
						,'LTSS - Perform Transition Visit Telephone'
						,'LTSS - Priority Outreach Contact - 4 Week Follow Up'

					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND TMPA.ACTIVE = 'Y'
					AND VMIA.INTERACTION_OUTCOME = 'LTSS Member/LAR left the state or Service Area'
					AND VMIA.INTERACTION_STATUS = 'Successful'
			)
			AND [How many successful telephonic service coordination or service management visits?] = 0

		--DEC; RANK 2
		UPDATE #BuildForNoTeleVisit
		SET [If no successful telephonic service coordination or service management visits made, why not?] = 'DEC'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 1'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 2'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						,'LTSS - IP Discharge Follow Up'
						,'LTSS - IP Discharge Follow Up outreach attempt 2'
						,'LTSS - IP Discharge Follow Up outreach attempt 3'
						,'LTSS - ER visit follow up Assessment'
						,'LTSS - ER follow up outreach attempt 2'
						,'LTSS - ER follow up outreach attempt 3'
						,'BH 7 Day Follow Up Call Back 1'
						,'BH 7 Day Follow Up Call Back 2'
						,'BH 7 Day Follow Up Call Back 3',
						/*Added 20220726 1734*/
						'LTSS - POC Transition Attempt 1',
						'LTSS - POC Transition Attempt 2',
						'LTSS - POC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 1',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 2',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 1',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 2',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 3'
						,'LTSS - Perform Transition Visit Telephone'
						,'LTSS - Priority Outreach Contact - 4 Week Follow Up'

					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND TMPA.ACTIVE = 'Y'
					AND VMIA.INTERACTION_OUTCOME IN ('LTSS Member/LAR Declined RTC', 'LTSS Member Requests Callback')
					AND VMIA.INTERACTION_STATUS = 'Successful'
			)
			AND [How many successful telephonic service coordination or service management visits?] = 0


		--MAR; WILL NOT BE AN OPTION

		--MDC; RANK LAST
		UPDATE #BuildForNoTeleVisit 
		SET [If no successful telephonic service coordination or service management visits made, why not?] = 'MDC'
		WHERE
			ENC_IDN IN (
				SELECT
					VMEA.ENC_IDN
				FROM
					[Zeomega].[dbo].[V_MODEL_EPISODE_ASSESSMENTS] VMEA (NOLOCK) 
				JOIN
					[Zeomega].[dbo].[V_MODEL_MEMBERS] VMM (NOLOCK) ON VMEA.MBR_IDN = VMM.MBR_IDN AND VMM.ACTIVE = 'Y'
				WHERE
					VMEA.TITLE = 'Deceased Member Checklist'
					AND VMEA.ACE_STATUS = 'Completed'
					AND VMEA.ACTIVE = 'Y'
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(VMM.DATE_OF_DEATH) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
			)
			AND [How many successful telephonic service coordination or service management visits?] = 0


		--OTH; OTHER
		UPDATE #BuildForNoTeleVisit
		SET [If no successful telephonic service coordination or service management visits made, why not?] = 'OTH'
		WHERE
			EligID IN (
				SELECT 
					TMPA.MBR_IDN
				FROM
					[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
				JOIN
					[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIA (NOLOCK) on  TMPA.MBR_IDN = VMMMIA.MBR_IDN 
																												and VMMMIA.ID_TYPE_CD = 'ALT'
																												and VMMMIA.active = 'Y'
				LEFT  JOIN 
					[Zeomega].[dbo].V_MODEL_MBR_MULTIPLE_IDS VMMMIE (NOLOCK) on TMPA.MBR_IDN = VMMMIE.MBR_IDN
																												and VMMMIE.ID_TYPE_CD = 'ELIG'
																												and VMMMIE.active = 'Y'
				WHERE
					TMPA.ACTIVITY IN (
						'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 1'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 2'
						,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 3'
						,'LTSS - Initial Outreach Attempt 1'
						,'LTSS - Initial Outreach Attempt 2'
						,'LTSS - Initial Outreach Attempt 3'
						,'LTSS - IP Discharge Follow Up'
						,'LTSS - IP Discharge Follow Up outreach attempt 2'
						,'LTSS - IP Discharge Follow Up outreach attempt 3'
						,'LTSS - ER visit follow up Assessment'
						,'LTSS - ER follow up outreach attempt 2'
						,'LTSS - ER follow up outreach attempt 3'
						,'BH 7 Day Follow Up Call Back 1'
						,'BH 7 Day Follow Up Call Back 2'
						,'BH 7 Day Follow Up Call Back 3',
						/*Added 20220726 1734*/
						'LTSS - POC Transition Attempt 1',
						'LTSS - POC Transition Attempt 2',
						'LTSS - POC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 1',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 2',
						'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 3',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 1',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 2',
						'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 3'
						,'LTSS - Perform Transition Visit Telephone'
						,'LTSS - Priority Outreach Contact - 4 Week Follow Up'

					)
					AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
					AND TMPA.ACTIVITY_STATUS = 'Closed'
					AND TMPA.ACTIVE = 'Y'
					AND VMIA.INTERACTION_STATUS NOT IN ('Successful', 'Unsuccessful')
			)
			AND [How many successful telephonic service coordination or service management visits?] = 0
			AND [If no successful telephonic service coordination or service management visits made, why not?] = ''

		--OTH AGAIN (PROBABLY THE ONLY OTH NEEDED)
		UPDATE #BuildForNoTeleVisit
		SET [If no successful telephonic service coordination or service management visits made, why not?] = 'OTH'
		WHERE
			[How many successful telephonic service coordination or service management visits?] = 0
			AND [If no successful telephonic service coordination or service management visits made, why not?] = ''

		--IF OTHER WHY?
		UPDATE #BuildForNoTeleVisit
		SET [If Other, provide brief description. (TELEPHONIC)] = 'Not TEL but activity outcome selected by the SC does not allow for categorization into the DEC, UTR, or MLT category'
		WHERE
			[If no successful telephonic service coordination or service management visits made, why not?] = 'OTH'

	END
END


/*Final*** Report Data*/
IF (1=1)
BEGIN

DROP TABLE IF EXISTS #BASE
SELECT DISTINCT
	LTSS.EligID
	,LTSS.MBR_IDN
	,LTSS.ENC_IDN
	/*Report start*/
	,LTSS.[Sequence]
	,LTSS.[MCO Name]
	,CAST(LTSS.[Reporting Month] AS VARCHAR(2)) [Reporting Month]
	,LTSS.[State Fiscal Year]
	,LTSS.[Program]
	,LTSS.[Plan Code] --42 star; KA star kids; 03 chip
	,LTSS.[Medicaid ID/PCN]
	,LTSS.[Member Date of Birth]
	,LTSS.[First Name]
	,LTSS.[Last Name]
	,LTSS.[Risk Group] --ratecode off enrollcoverage
	,LTSS.[Is this Member new to the MCO in the reporting month?] --Empty. Need to figure this out

	,LTSS.[Is this Member newly identified as MSHCN in the reporting month.]

	,LTSS.[Did the Member decline service coordination or service management?] --"Most Current" Am I looking for this?
	,LTSS.[If yes, why was service coordination or service management declined?]
	,LTSS.[If Other entered, enter a brief explanation]

	,ISNULL(SKS.[Does the Member have a service plan in place?],'02') AS [Does the Member have a service plan in place?]

	,CASE
		WHEN LTSS.[If yes, why was service coordination or service management declined?] IN ('DEC', 'MLT') 
			AND ISNULL(SKS.[Does the Member have a service plan in place?],'02') = '02' THEN LTSS.[If yes, why was service coordination or service management declined?]
		WHEN LTSS.[If yes, why was service coordination or service management declined?] IN ('OTH') 
			AND ISNULL(SKS.[Does the Member have a service plan in place?],'02') = '02' THEN 'DEC' --MEETING WITH ROXANNE 20220725
		ELSE NSPR.[If the Member does not have a service plan in place, select the appropriate reason. ] 
	END AS [If the Member does not have a service plan in place, select the appropriate reason. ]
	,NSPR.[If "Other" selected, provide a brief explanation. ] AS [If "Other" selected, provide a brief explanation. ]
	,CAST(NULL AS VARCHAR(10)) AS [Date the service plan was developed or last updated?]

	,ISNULL(CAST('0' AS CHAR(1)) + RIGHT(LOS.[What is the Members service coordination or service management level?],1),'06')  AS [What is the Members service coordination or service management level?]
	,CAST('' AS VARCHAR(2)) AS [Was at least one service coordination or service management contact attempt made? ]

	/*******************************/
	,CAST(ISNULL(F.[F2F COUNT], 0) AS VARCHAR(2)) [How many successful face-to-face service coordination or service management visits?]
	/*******************************/

	,NF2FR.[If no successful face-to-face service coordination or service management visits, why not?] AS [If no successful face-to-face service coordination or service management visits, why not?]
	,NF2FR.[If Other, provide brief description. (F2F)] AS [If Other, provide brief description. (F2F)]

	,CAST(ISNULL(TELE.[TELE COUNT], 0) AS VARCHAR(2)) AS [How many successful telephonic service coordination or service management visits?]

	,ISNULL(NOTELE.[If no successful telephonic service coordination or service management visits made, why not?], '') [If no successful telephonic service coordination or service management visits made, why not?]
	,ISNULL(NOTELE.[If Other, provide brief description. (TELEPHONIC)], '') [If Other, provide brief description. (TELEPHONIC)]
INTO #BASE
FROM
	#LTSS LTSS
LEFT JOIN
	#f2FCounts F ON LTSS.EligID = F.EligID
LEFT JOIN
	#SKScreen SKS ON LTSS.EligID = SKS.EligID 
LEFT JOIN
	#LevelOfSupport LOS ON LTSS.EligID = LOS.EligID
LEFT JOIN
	#TeleVisitCounts TELE ON LTSS.EligID = TELE.EligID
LEFT JOIN
	#BuildForNoFTFReason NF2FR ON LTSS.EligID = NF2FR.EligID
LEFT JOIN
	#BuildForNoSPReason NSPR ON LTSS.EligID = NSPR.EligID
LEFT JOIN
	#BuildForNoTeleVisit NOTELE ON LTSS.EligID = NOTELE.EligID
WHErE
	LTSS.EligID IS NOT NULL  --AND LTSS.[Medicaid ID/PCN] = '727515186'
ORDER BY
	1,2,3,10


UPDATE  B
SET B.[Date the service plan was developed or last updated?] = REPLACE(CONVERT(DATE,(
	SELECT TOP 1
		X.[UPDATED_DATE]
	FROM
		(
		SELECT
			VMSPD.MBR_IDN
			,VMSPD.MEMBER_ID
			,VMSPSD.[UPDATED_DATE]
			,VMSPD.ISP_END_DATE
			,ROW_NUMBER() OVER(PARTITION BY VMSPD.MEMBER_ID, VMSPD.MBR_IDN ORDER BY VMSPD.ISP_END_DATE) R
		FROM
			[Zeomega].[dbo].V_MODEL_SERVICE_PLAN_DETAILS VMSPD (NOLOCK) 
		JOIN
			[Zeomega].[dbo].V_MODEL_SERVICE_PLAN_SERVICE_DETAILS VMSPSD (NOLOCK) ON VMSPD.ISP_IDN = VMSPSD.ISP_IDN
		WHERE
			--VMSPD.[STATUS] IN ('Open', 'Completed') --Meeting with Roxanne 20220726
			--AND 
			(@reportMonthStart BETWEEN VMSPD.ISP_START_DATE AND VMSPD.ISP_END_DATE OR @reportMonthEnd BETWEEN VMSPD.ISP_START_DATE AND VMSPD.ISP_END_DATE)
			AND VMSPD.MEMBER_ID = B.[Medicaid ID/PCN] COLLATE DATABASE_DEFAULT
		) X
		WHERE
			X.R = 1
), 110), '-', '')
FROM #BASE B
WHERE
	B.[Does the Member have a service plan in place?] = '01'


--When MEMBER_ID IS NULL
UPDATE  B
SET B.[Date the service plan was developed or last updated?] = REPLACE(CONVERT(DATE, (
	SELECT TOP 1
		X.[UPDATED_DATE]
	FROM
		(
		SELECT
			VMSPD.MBR_IDN
			,VMSPD.MEMBER_ID
			,VMSPSD.[UPDATED_DATE]
			,VMSPD.ISP_END_DATE
			,ROW_NUMBER() OVER(PARTITION BY VMSPD.MEMBER_ID, VMSPD.MBR_IDN ORDER BY VMSPD.ISP_END_DATE) R
		FROM
			[Zeomega].[dbo].V_MODEL_SERVICE_PLAN_DETAILS VMSPD (NOLOCK) 
		JOIN
			[Zeomega].[dbo].V_MODEL_SERVICE_PLAN_SERVICE_DETAILS VMSPSD (NOLOCK) ON VMSPD.ISP_IDN = VMSPSD.ISP_IDN
		WHERE
			--VMSPD.[STATUS] IN ('Open', 'Completed') --Meeting with Roxanne 20220726
			--AND 
			(@reportMonthStart BETWEEN VMSPD.ISP_START_DATE AND VMSPD.ISP_END_DATE OR @reportMonthEnd BETWEEN VMSPD.ISP_START_DATE AND VMSPD.ISP_END_DATE)
			AND VMSPD.MBR_IDN = B.EligID 
		) X
		WHERE
			X.R = 1
), 110), '-', '')
FROM #BASE B
WHERE
	B.[Does the Member have a service plan in place?] = '01'
	AND B.[Date the service plan was developed or last updated?] IS NULL




--/*Where ever the count is 0, it needs to be changed to the count of Closed Sucessful Activities in the list, so long as they aren't DEC or MLT.*/
UPDATE B
SET [How many successful telephonic service coordination or service management visits?] = (
	SELECT --*
		COUNT(*)
	FROM
		[Zeomega].[dbo].V_MODEL_ACTIVITIES TMPA (NOLOCK)
	JOIN
		[Zeomega].[dbo].V_MODEL_INTERACTIONS VMIA (NOLOCK) ON TMPA.ACT_IDN = VMIA.ACT_IDN
	WHERE
		TMPA.ACTIVITY IN (
			'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 1'
			,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 2'
			,'LTSS - Priority Outreach Contact - Required Telephone Contact LOS 3'
			,'LTSS - Initial Outreach Attempt 1'
			,'LTSS - Initial Outreach Attempt 2'
			,'LTSS - Initial Outreach Attempt 3'
			,'LTSS - IP Discharge Follow Up'
			,'LTSS - IP Discharge Follow Up outreach attempt 2'
			,'LTSS - IP Discharge Follow Up outreach attempt 3'
			,'LTSS - ER visit follow up Assessment'
			,'LTSS - ER follow up outreach attempt 2'
			,'LTSS - ER follow up outreach attempt 3'
			,'BH 7 Day Follow Up Call Back 1'
			,'BH 7 Day Follow Up Call Back 2'
			,'BH 7 Day Follow Up Call Back 3',
			/*Added 20220726 1734*/
			'LTSS - POC Transition Attempt 1',
			'LTSS - POC Transition Attempt 2',
			'LTSS - POC Transition Attempt 3',
			'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 1',
			'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 2',
			'LTSS - MDCP/PDN/PPECC POC - RTC Transition Attempt 3',
			'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 1',
			'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 2',
			'LTSS - MDCP/PDN/PPECC Perform Quarterly RTC - 3'
			,'LTSS - Perform Transition Visit Telephone'
			,'LTSS - Priority Outreach Contact - 4 Week Follow Up'

		)
		AND CAST(JIVA.dbo.fn_GetDaylightSavingsTimeAdjusted(TMPA.UPDATED_DATE) AS DATE) BETWEEN @reportMonthStart AND @reportMonthEnd
		AND TMPA.ACTIVITY_STATUS = 'Closed'
		AND TMPA.ACTIVE = 'Y'
		AND VMIA.INTERACTION_STATUS = 'Successful'
		AND B.EligID = TMPA.MBR_IDN
	)
FROM #BASE B
WHERE
	B.[How many successful telephonic service coordination or service management visits?] = 0
	AND B.[If no successful telephonic service coordination or service management visits made, why not?] NOT IN ('DEC', 'MLT')


UPDATE #BASE
SET [If no successful telephonic service coordination or service management visits made, why not?] = ''
	,[If Other, provide brief description. (TELEPHONIC)] = ''
WHERE
	[How many successful telephonic service coordination or service management visits?] > 0

UPDATE #BASE
SET [Was at least one service coordination or service management contact attempt made? ] = 
	CASE
		WHEN [If no successful face-to-face service coordination or service management visits, why not?] = 'F2F' 
			AND [If no successful telephonic service coordination or service management visits made, why not?]= 'TEL' THEN '02'
		ELSE '01'
	END





DROP TABLE IF EXISTS #FINAL
SELECT
	[Sequence] = ROW_NUMBER() OVER(ORDER BY [Medicaid ID/PCN])
	,[MCO Name]
	,[Reporting Month] = CASE WHEN LEN([Reporting Month]) = 1 THEN CONCAT('0',[Reporting Month]) ELSE [Reporting Month] END
	,[State Fiscal Year]
	,[Program]
	,[Plan Code]
	,[Medicaid ID/PCN]
	,[Member Date of Birth] = REPLACE(CONVERT(VARCHAR(10), [Member Date of Birth], 110),'-','')
	,[First Name]
	,[Last Name]
	,[Risk Group]
	,[Is this Member new to the MCO in the reporting month?]
	,'' AS [Is this Member newly identified as MSHCN in the reporting month.]
	,[Did the Member decline service coordination or service management?]
	
	-----MEETING WITH ROXANNE 20220725----------------------------------------------------------------------------------------
	,CASE
		WHEN [Did the Member decline service coordination or service management?] = '02' THEN ''
		ELSE CASE
				WHEN [If yes, why was service coordination or service management declined?] = 'OTH' THEN 'DEC'
				ELSE [If yes, why was service coordination or service management declined?]
			END
	END AS [If yes, why was service coordination or service management declined?]
	
	--,CASE
	--	WHEN [Did the Member decline service coordination or service management?] = '01' AND [If yes, why was service coordination or service management declined?] = 'OTH' THEN [If Other entered, enter a brief explanation]
	--	ELSE ''
	--END AS [If Other entered, enter a brief explanation]

	,'' AS [If Other entered, enter a brief explanation]

	--------MEETING WITH ROXANNE 20220725-----------------------------------------------------------------------------------
	
	,[Does the Member have a service plan in place?]
	
	,CASE
		WHEN [Does the Member have a service plan in place?] = '01' THEN ''
		ELSE [If the Member does not have a service plan in place, select the appropriate reason. ]
	END AS [If the Member does not have a service plan in place, select the appropriate reason. ]
	
	,CASE
		WHEN [Does the Member have a service plan in place?] = '02' AND [If the Member does not have a service plan in place, select the appropriate reason. ] = 'OTH' THEN [If "Other" selected, provide a brief explanation. ]
		ELSE ''
	END [If "Other" selected, provide a brief explanation. ]
	
	,CONCAT(SUBSTRING([Date the service plan was developed or last updated?],5,4),LEFT([Date the service plan was developed or last updated?],4)) AS [Date the service plan was developed or last updated?]
	,[What is the Members service coordination or service management level?]
	,[Was at least one service coordination or service management contact attempt made? ]
	,CAST(CASE	
		WHEN [Was at least one service coordination or service management contact attempt made? ] = '02' THEN ''
		ELSE [How many successful face-to-face service coordination or service management visits?]
	END AS VARCHAR(2)) [How many successful face-to-face service coordination or service management visits?]
	,CASE	
		WHEN [Was at least one service coordination or service management contact attempt made? ] = '02' THEN ''
		ELSE CASE
				WHEN [How many successful face-to-face service coordination or service management visits?] > 0 THEN ''
				ELSE [If no successful face-to-face service coordination or service management visits, why not?]
			 END
	END AS [If no successful face-to-face service coordination or service management visits, why not?]
	,CASE
		WHEN [Was at least one service coordination or service management contact attempt made? ] = '02' THEN ''
		ELSE [If Other, provide brief description. (F2F)]
	END AS [If Other, provide brief description. (F2F)]
	,CAST(CASE
		WHEN [Was at least one service coordination or service management contact attempt made? ] = '02' THEN ''
		ELSE [How many successful telephonic service coordination or service management visits?]
	END AS VARCHAR(2)) [How many successful telephonic service coordination or service management visits?]
	,CASE
		WHEN [Was at least one service coordination or service management contact attempt made? ] = '02' THEN ''
		ELSE [If no successful telephonic service coordination or service management visits made, why not?]
	END AS [If no successful telephonic service coordination or service management visits made, why not?]
	,CASE
		WHEN [Was at least one service coordination or service management contact attempt made? ] = '02' THEN ''
		ELSE [If Other, provide brief description. (TELEPHONIC)]
	END AS [If Other, provide brief description. (TELEPHONIC)]
INTO #FINAL
FROM
	#BASE



SELECT DISTINCT
[Sequence]
	,[MCO Name]
	,[Reporting Month] 
	,[State Fiscal Year]
	,[Program]
	,[Plan Code]
	,[Medicaid ID/PCN]
	,[Member Date of Birth]
	,[First Name]
	,[Last Name]
	,[Risk Group]
	,[Is this Member new to the MCO in the reporting month?]
	,[Is this Member newly identified as MSHCN in the reporting month.]
	,[Did the Member decline service coordination or service management?]
	,[If yes, why was service coordination or service management declined?]
	,[If Other entered, enter a brief explanation]
	,[Does the Member have a service plan in place?]
	
	,[If the Member does not have a service plan in place, select the appropriate reason. ]
	
	,[If "Other" selected, provide a brief explanation. ]
	
	,[Date the service plan was developed or last updated?]
	,[What is the Members service coordination or service management level?]
	,[Was at least one service coordination or service management contact attempt made? ]

	,[How many successful face-to-face service coordination or service management visits?]
	,CASE
		WHEN 
			[Did the Member decline service coordination or service management?] = '01' AND [If no successful face-to-face service coordination or service management visits, why not?] = 'OTH'
			THEN [If yes, why was service coordination or service management declined?]
		ELSE [If no successful face-to-face service coordination or service management visits, why not?]
	END AS [If no successful face-to-face service coordination or service management visits, why not?]
	,CASE
		WHEN [Did the Member decline service coordination or service management?] = '01' THEN ''
		ELSE [If Other, provide brief description. (F2F)] 
	END AS [If Other, provide brief description. (F2F)]


	,[How many successful telephonic service coordination or service management visits?]
	,CASE
		WHEN [Did the Member decline service coordination or service management?] = '01' AND [If no successful telephonic service coordination or service management visits made, why not?] = 'OTH'
			THEN [If yes, why was service coordination or service management declined?]
		ELSE [If no successful telephonic service coordination or service management visits made, why not?]
	END AS [If no successful telephonic service coordination or service management visits made, why not?]
	,CASE	
		WHEN [Did the Member decline service coordination or service management?] = '01' THEN '' 
		ELSE [If Other, provide brief description. (TELEPHONIC)]
	END AS [If Other, provide brief description. (TELEPHONIC)]
	
FROM
	#FINAL



END
END
