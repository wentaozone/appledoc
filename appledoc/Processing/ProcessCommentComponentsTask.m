//
//  ProcessCommentComponentsTask.m
//  appledoc
//
//  Created by Tomaz Kragelj on 8/12/12.
//  Copyright (c) 2012 Tomaz Kragelj. All rights reserved.
//

#import "Objects.h"
#import "CommentInfo.h"
#import "CommentComponentInfo.h"
#import "CommentNamedSectionInfo.h"
#import "ProcessCommentComponentsTask.h"

@interface ProcessComponentsData : NSObject
@property (nonatomic, strong) NSMutableString *builder;
@property (nonatomic, strong) NSMutableArray *sections;
@end

@implementation ProcessComponentsData @end

#pragma mark -

@implementation ProcessCommentComponentsTask

#pragma mark - Processing

- (NSInteger)processComment:(CommentInfo *)comment {
	LogProInfo(@"Processing comment '%@' for components...", [comment.sourceString gb_description]);
	
	// Prepare internal data.
	ProcessComponentsData *data = [[ProcessComponentsData alloc] init];
	data.builder = [@"" mutableCopy];
	data.sections = [@[] mutableCopy];
	
	// Parse comment string into sections.
	[self parseSectionsFromComment:comment toData:data];
	[self registerSectionFromBuilderInData:data startNewSection:NO];
	if (data.sections.count == 0) return GBResultOk;
	
	// Process sections into comment components.
	[self registerAbstractFromData:data toComment:comment];
	[self registerDiscussionFromData:data toComment:comment];
	[self registerMethodFromData:data toComment:comment];
}

#pragma mark - Splitting source string to sections

- (void)parseSectionsFromComment:(CommentInfo *)comment toData:(ProcessComponentsData *)data {
	LogProDebug(@"Parsing comment string into sections...");
	NSRegularExpression *expression = [NSRegularExpression gb_emptyLineMatchingExpression];
	NSString *sourceString = comment.sourceString;
	__weak ProcessCommentComponentsTask *bself = self;
	__block NSUInteger index = 0;
	[expression gb_allMatchesIn:sourceString match:^(NSTextCheckingResult *match, NSUInteger idx, BOOL *stop) {
		NSRange range = NSMakeRange(index, match.range.location - index);
		NSString *section = [sourceString substringWithRange:range];
		[bself parseSectionsFromString:section toData:data];
		index = match.range.location + match.range.length;
	}];
	NSString *remainingString = [sourceString substringFromIndex:index];
	[self parseSectionsFromString:remainingString toData:data];
}

- (void)parseSectionsFromString:(NSString *)sectionString toData:(ProcessComponentsData *)data {
	if (sectionString.length == 0) return;

	// If current "paragraph" starts with section directive, we must split the whole string into individual sections, each directive starting new section.
	NSRegularExpression *sectionExpression = [NSRegularExpression gb_sectionDelimiterMatchingExpression];
	NSArray *sectionMatches = [sectionExpression gb_allMatchesIn:sectionString];
	if (sectionMatches.count > 0 && [sectionMatches[0] range].location == 0) {
		// Register current builder as section, if needed.
		if (data.builder.length > 0) [self registerSectionFromBuilderInData:data startNewSection:YES];

		// Register all directives from current section string.
		__weak ProcessCommentComponentsTask *bself = self;
		__block NSUInteger lastMatchLocation = 0;
		[sectionMatches enumerateObjectsUsingBlock:^(NSTextCheckingResult *match, NSUInteger idx, BOOL *stop) {
			if (idx == 0) return;
			NSString *currentSectionString = [[match gb_prefixFromIndex:lastMatchLocation in:sectionString] gb_stringByTrimmingNewLines];
			[data.builder appendString:currentSectionString];
			[bself registerSectionFromBuilderInData:data startNewSection:YES];
			lastMatchLocation = match.range.location;
		}];
		
		// Register remaining section, but keep the string so we can append subsequent paragraphs to it.
		NSString *remainingSectionString = [[sectionString substringFromIndex:lastMatchLocation] gb_stringByTrimmingNewLines];
		[data.builder appendString:remainingSectionString];
		[self registerSectionFromBuilderInData:data startNewSection:NO];
		return;
	}
	
	// If this is the first paragraph to be registered, take it as abstract and create single section out of it.
	if (data.sections.count == 0) {
		LogProDebug(@"Detected abstract '%@'...", [sectionString gb_description]);
		[data.builder appendString:sectionString];
		[self registerSectionFromBuilderInData:data startNewSection:YES];
		return;
	}
	
	// Otherwise append "normal" paragraph to current section builder to be registered later on.
	LogProDebug(@"Appending paragraph '%@'...", [sectionString gb_description]);
	if (data.builder.length > 0) [data.builder appendString:@"\n\n"];
	[data.builder appendString:[sectionString gb_stringByTrimmingNewLines]];
}

- (void)registerSectionFromBuilderInData:(ProcessComponentsData *)data startNewSection:(BOOL)startNew {
	// Note that we need to handle special case where current builder string is the same pointer as last object; in such case we can ignore it, but we do need to clear the string!
	if (data.builder.length == 0) return;
	if (data.builder == data.sections.lastObject) { data.builder=[@"" mutableCopy]; return; }
	LogProDebug(@"Registering section '%@'...", [data.builder gb_description]);
	[data.sections addObject:data.builder];
	if (startNew) data.builder = [@"" mutableCopy];
}

#pragma mark - Registering sections to comment

- (void)registerAbstractFromData:(ProcessComponentsData *)data toComment:(CommentInfo *)comment {
	LogProDebug(@"Registering abstract...");
	CommentComponentInfo *component = [CommentComponentInfo componentWithSourceString:data.sections[0]];
	[comment setCommentAbstract:component];
	[data.sections removeObjectAtIndex:0];
}

- (void)registerDiscussionFromData:(ProcessComponentsData *)data toComment:(CommentInfo *)comment {
	// Register all discussion sections - up until first parameter related section.
	NSRegularExpression *expression = [NSRegularExpression gb_methodSectionDelimiterMatchingExpression];
	CommentSectionInfo *discussion = nil;
	while (data.sections.count > 0) {
		NSString *sectionString = data.sections[0];
		NSTextCheckingResult *match = [expression gb_firstMatchIn:sectionString];
		if (match && match.range.location == 0) break;
		if (!discussion) discussion = [[CommentSectionInfo alloc] init];
		CommentComponentInfo *component = [CommentComponentInfo componentWithSourceString:sectionString];
		[discussion.sectionComponents addObject:component];
		[data.sections removeObjectAtIndex:0];
	}
	if (discussion) [comment setCommentDiscussion:discussion];
}

- (void)registerMethodFromData:(ProcessComponentsData *)data toComment:(CommentInfo *)comment {
	NSMutableArray *parameters = nil;
	NSMutableArray *exceptions = nil;
	CommentSectionInfo *result = nil;
	CommentSectionInfo *lastSection = nil;
	while (data.sections.count > 0) {
		NSString *sectionString = data.sections[0];
		if ([self matchParameterSectionFromString:sectionString sections:data.sections toArray:&parameters]) continue;
		if ([self matchExceptionSectionFromString:sectionString sections:data.sections toArray:&exceptions]) continue;
		if ([self matchReturnSectionFromString:sectionString sections:data.sections toInfo:&result]) continue;
		break;
	}
	if (parameters) [comment setCommentParameters:parameters];
	if (exceptions) [comment setCommentExceptions:exceptions];
	if (result) [comment setCommentReturn:result];
}

#pragma mark - Matching method directives

- (BOOL)matchParameterSectionFromString:(NSString *)string sections:(NSMutableArray *)sections toArray:(NSMutableArray **)array {
	NSRegularExpression *expression = [NSRegularExpression gb_paramMatchingExpression];
	return [self matchNamedMethodSectionFromString:string expression:expression sections:sections toArray:array];
}

- (BOOL)matchExceptionSectionFromString:(NSString *)string sections:(NSMutableArray *)sections toArray:(NSMutableArray **)array {
	NSRegularExpression *expression = [NSRegularExpression gb_exceptionMatchingExpression];
	return [self matchNamedMethodSectionFromString:string expression:expression sections:sections toArray:array];
}

- (BOOL)matchReturnSectionFromString:(NSString *)string sections:(NSMutableArray *)sections toInfo:(CommentSectionInfo **)dest {
	NSRegularExpression *expression = [NSRegularExpression gb_returnMatchingExpression];
	return [self matchSimpleSectionFromString:string expression:expression sections:sections toInfo:dest];
}

- (BOOL)matchNamedMethodSectionFromString:(NSString *)string expression:(NSRegularExpression *)expression sections:(NSMutableArray *)sections toArray:(NSMutableArray **)array {
	NSTextCheckingResult *match = [expression gb_firstMatchIn:string];
	if (!match) return NO;
	NSString *description = [match gb_remainingStringIn:string];
	CommentComponentInfo *component = [CommentComponentInfo componentWithSourceString:description];
	CommentNamedSectionInfo *info = [[CommentNamedSectionInfo alloc] init];
	[info setSectionName:[match gb_stringAtIndex:2 in:string]];
	[info.sectionComponents addObject:component];
	if (!*array) *array = [@[] mutableCopy];
	[*array addObject:info];
	[sections removeObjectAtIndex:0];
	return YES;
}

- (BOOL)matchSimpleSectionFromString:(NSString *)string expression:(NSRegularExpression *)expression sections:(NSMutableArray *)sections toInfo:(CommentSectionInfo **)dest {
	NSTextCheckingResult *match = [expression gb_firstMatchIn:string];
	if (!match) return NO;
	NSString *description = [match gb_remainingStringIn:string];
	CommentComponentInfo *component = [CommentComponentInfo componentWithSourceString:description];
	CommentSectionInfo *info = [[CommentSectionInfo alloc] init];
	[info.sectionComponents addObject:component];
	*dest = info;
	[sections removeObjectAtIndex:0];
	return YES;
}

#pragma mark - Comment components handling

- (CommentComponentInfo *)componentInfoFromString:(NSString *)string {
	LogProDebug(@"Creating component for %@...", string);
	CommentComponentInfo *result = [[CommentComponentInfo alloc] init];
	result.sourceString = string;
	return result;
}

@end
